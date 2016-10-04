require 'coffee-script'
require 'json'
require 'rufus/scheduler'
require 'redis-objects'
require 'connection_pool'
require 'sass'
require 'sinatra'
require 'sinatra/content_for'
require 'sprockets'
require 'uglifier'
require 'execjs'
require 'yaml'
require 'uri'
require 'thin'

SCHEDULER = Rufus::Scheduler.new
REDIS_CHANNEL = 'dashing/events'.freeze

def development?
  ENV['RACK_ENV'] == 'development'
end

def production?
  ENV['RACK_ENV'] == 'production'
end

def redis_connection_pool_config
  { size:    ENV.fetch('REDIS_POOL_SIZE', 5),
    timeout: ENV.fetch('REDIS_POOL_TIMEOUT', 5) }
end

def new_redis_connection
  uri = URI.parse(ENV['REDIS_URI'] || 'redis://localhost:6379')

  Redis.new(host: uri.host, port: uri.port, password: uri.password)
end

Redis::Objects.redis = ConnectionPool.new(redis_connection_pool_config) { new_redis_connection }

Thread.new do
  new_redis_connection.subscribe(REDIS_CHANNEL) do |on|
    on.message do |channel, message|
      send_to_connections message
    end
  end
end

helpers Sinatra::ContentFor
helpers do
  def protected!
    # override with auth logic
  end

  def authenticated?(token)
    return true unless settings.auth_token
    token && Rack::Utils.secure_compare(settings.auth_token, token)
  end
end

set :root, Dir.pwd
set :sprockets,     Sprockets::Environment.new(settings.root)
set :assets_prefix, '/assets'
set :public_folder, File.join(settings.root, 'public')
set :views, File.join(settings.root, 'dashboards')
set :default_dashboard, nil
set :auth_token, nil

set server: 'thin', connections: []
set history: Redis::HashKey.new('dashing/history', marshal: true)

%w(javascripts stylesheets fonts images).each do |path|
  settings.sprockets.append_path("assets/#{path}")
end

configure :production do
  set :static, :true
  set :static_cache_control, [:public, { max_age:  60 * 60 * 24 * 365 }]

  settings.sprockets.css_compressor = :scss
  settings.sprockets.js_compressor  = Uglifier.new(mangle: false)
end

['widgets', File.expand_path('../../../javascripts', __FILE__)]. each do |path|
  settings.sprockets.append_path(path)
end

not_found do
  send_file File.join(settings.public_folder, '404.html'), status: 404
end

get '/' do
  protected!
  dashboard = settings.default_dashboard || first_dashboard
  raise Exception.new('There are no dashboards available') if not dashboard

  redirect "/" + dashboard
end


get '/events', provides: 'text/event-stream' do
  protected!
  response.headers['X-Accel-Buffering'] = 'no' # Disable buffering for nginx
  stream(true) do |out|
    settings.connections << connection = {out: out, mutex: Mutex.new}

    out << settings.history[:latest_events]
    out.callback { settings.connections.delete(connection) }
  end
end

get '/:dashboard' do
  protected!
  tilt_html_engines.each do |suffix, _|
    file = File.join(settings.views, "#{params[:dashboard]}.#{suffix}")
    return render(suffix.to_sym, params[:dashboard].to_sym) if File.exist? file
  end

  halt 404
end

post '/dashboards/:id' do
  request.body.rewind
  body = JSON.parse(request.body.read)
  body['dashboard'] ||= params['id']
  if authenticated?(body.delete("auth_token"))
    create_event_and_send_event(params['id'], body, 'dashboards')
    204 # response without entity body
  else
    status 401
    "Invalid API key\n"
  end
end

post '/widgets/:id' do
  request.body.rewind
  body = JSON.parse(request.body.read)
  if authenticated?(body.delete("auth_token"))
    create_event_and_send_event(params['id'], body)
    204 # response without entity body
  else
    status 401
    "Invalid API key\n"
  end
end

get '/views/:widget?.html' do
  protected!
  tilt_html_engines.each do |suffix, engines|
    file = File.join(settings.root, "widgets", params[:widget], "#{params[:widget]}.#{suffix}")
    return engines.first.new(file).render if File.exist? file
  end
end

Thin::Server.class_eval do
  def stop_with_connection_closing
    Sinatra::Application.settings.connections.dup.each(&:close)

    stop_without_connection_closing
  end

  alias_method :stop_without_connection_closing, :stop
  alias_method :stop, :stop_with_connection_closing
end

def history
  Sinatra::Application.settings.history
end

def create_event_and_send_event(id, body, target = nil)
  body[:id] = id
  body[:updatedAt] ||= Time.now.to_i

  event = format_event(body.to_json, target)

  add_to_history id, event unless target == 'dashboards'
  publish_to_redis event
end

def send_to_connections(event)
  Sinatra::Application.settings.connections.each do |connection|
    connection[:mutex].synchronize do
      out = connection[:out]
      begin
        out << event unless out.closed?
      rescue => e
        puts e
      end
    end
  end
end

def publish_to_redis(event)
  Redis.current.publish REDIS_CHANNEL, event
end

def add_to_history(id, event)
  Redis.current.multi do
    history[id] = event
    history[:latest_events] = history.each.inject("") do |str, (key, body)|
      str << body unless key == 'latest_events'
      str
    end
  end
end

def format_event(body, name=nil)
  str = ""
  str << "event: #{name}\n" if name
  str << "data: #{body}\n\n"
end

def first_dashboard
  files = Dir[File.join(settings.views, '*')].collect { |f| File.basename(f, '.*') }
  files.reject! { |file| file =~ /\A_|\Alayout\z/ }
  files.sort!
  files.first
end

def tilt_html_engines
  Tilt.mappings.select do |_, engines|
    default_mime_type = engines.first.default_mime_type
    default_mime_type.nil? || default_mime_type == 'text/html'
  end
end

def require_glob(relative_glob)
  Dir[File.join(settings.root, relative_glob)].each do |file|
    require file
  end
end

settings_file = File.join(settings.root, 'config/settings.rb')
require settings_file if File.exists?(settings_file)

{}.to_json # Forces your json codec to initialize (in the event that it is lazily loaded). Does this before job threads start.
job_path = ENV["JOB_PATH"] || 'jobs'
require_glob(File.join('lib', '**', '*.rb'))
require_glob(File.join(job_path, '**', '*.rb'))
