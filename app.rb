$:.unshift(File.dirname(__FILE__))
$:.unshift(File.dirname(__FILE__) + '/lib')
$:.unshift(File.dirname(__FILE__) + '/../yard/lib')

require 'yard'
require 'sinatra'
require 'json'
require 'yaml'
require 'fileutils'
require 'open-uri'
require 'rack/hoptoad'

require 'init'
require 'extensions'
require 'scm_router'
require 'scm_checkout'
require 'gems_router'

class DocServer < Sinatra::Base
  include YARD::Server

  def self.adapter_options
    caching = %w(staging production).include?(ENV['RACK_ENV'])
    {
      :libraries => {},
      :options => {caching: caching, single_library: false},
      :server_options => {DocumentRoot: STATIC_PATH}
    }
  end
  
  def self.load_configuration
    return unless File.file?(CONFIG_FILE)
    puts ">> Loading #{CONFIG_FILE}"
    YAML.load_file(CONFIG_FILE).each do |key, value|
      set key, value
    end
  end
  
  def self.copy_static_files
    # Copy template files
    puts ">> Copying static system files..."
    Commands::StaticFileCommand::STATIC_PATHS.each do |path|
      %w(css js images).each do |ext|
        next unless File.directory?(File.join(path, ext))
        system "cp #{File.join(path, ext, '*')} #{File.join('public', ext, '')}"
      end
    end
  end
  
  def self.load_gems_adapter
    remote_file = File.dirname(__FILE__) + "/remote_gems"
    contents = File.readlines(remote_file)
    puts ">> Loading remote gems list..."
    opts = adapter_options
    contents.each do |line|
      name, *versions = *line.split(/\s+/)
      opts[:libraries][name] = versions.map {|v| LibraryVersion.new(name, v, nil, :remote_gem) }
    end
    opts[:options][:router] = GemsRouter
    set :gems_adapter, RackAdapter.new(*opts.values)
  rescue Errno::ENOENT
    log.error "No remote_gems file to load remote gems from, not serving gems."
  end
  
  def self.load_scm_adapter
    opts = adapter_options
    opts[:options][:router] = ScmRouter
    opts[:libraries] = ScmLibraryStore.new
    set :scm_adapter, RackAdapter.new(*opts.values)
  end

  use Rack::Deflater
  use Rack::ConditionalGet
  use Rack::Head

  enable :static
  enable :dump_errors
  enable :lock
  disable :caching
  disable :raise_errors

  set :views, TEMPLATES_PATH
  set :public, STATIC_PATH
  set :repos, REPOS_PATH
  set :tmp, TMP_PATH

  configure(:production) do
    enable :caching
    enable :logging
    # log to file
    file = File.open("sinatra.log", "a")
    STDOUT.reopen(file)
    STDERR.reopen(file)
  end
  
  configure do
    load_configuration
    load_gems_adapter
    load_scm_adapter
    copy_static_files
  end
  
  helpers do
    include ScmCheckout
    
    def notify_error
      if options.hoptoad && %w(staging production).include?(ENV['RACK_ENV'])
        @hoptoad_notifier ||= Rack::Hoptoad.new(self, options.hoptoad)
        @hoptoad_notifier.send(:send_notification, request.env['sinatra.error'], request.env)
      end
      erb(:error)
    end
    
    def cache(output)
      return output if options.caching != true
      path = request.path.gsub(%r{^/|/$}, '')
      path = File.join(options.public, path + '.html')
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "w") {|f| f.write(output) }
      output
    end
    
    def next_row(prefix = 'r', base = 1)
      prefix + (@row = @row == base ? base + 1 : base).to_s
    end
    
    def translate_file_links(extra)
      extra.sub(%r{^/(frames/)?file:}, '/\1file/')
    end
  end
  
  # Checkout and post commit hooks
  
  post '/checkout' do
    if params[:payload]
      payload = JSON.parse(params[:payload])
      url = payload["repository"]["url"].gsub(%r{^http://}, 'git://')
      scheme = "git"
      commit = nil
    else
      scheme = params[:scheme]
      url = params[:url]
      commit = params[:commit]
    end
    dirname = File.basename(url).gsub(/\.[^.]+\Z/, '').gsub(/\s+/, '')
    return "INVALIDSCHEME" unless url.include?("://")
    case scheme
    when "git", "svn"
      fork { checkout(url, dirname, commit, scheme) }
      "OK"
    else
      "INVALIDSCHEME"
    end
  end

  get '/checkout/:username/:project/:commit' do
    projname = params[:username] + '/' + params[:project]
    if libs = options.scm_adapter.libraries[projname]
      return "YES" if libs.find {|l| l.version == params[:commit] }
    end
    
    if File.file?("#{options.tmp}/#{projname}.error.txt")
      "ERROR"
    else
      "NO"
    end
  end
  
  # Main URL handlers
  
  get '/github/?' do
    @adapter = options.scm_adapter
    @libraries = @adapter.libraries
    cache erb(:scm_index)
  end
  
  get %r{^/gems(?:/([a-z])?)?$} do |letter|
    @letter = letter || 'a'
    @adapter = options.gems_adapter
    @libraries = @adapter.libraries.find_all {|k, v| k[0].downcase == @letter }
    cache erb(:gems_index)
  end
  
  get %r{^/((search|list)/)?github(/|$)} do
    options.scm_adapter.call(env)
  end

  get %r{^/((search|list)/)?gems(/|$)} do
    options.gems_adapter.call(env)
  end

  # Old URL structure redirection for yardoc.org
  
  get(%r{^/docs/([^/]+)-([^/]+)(/?.*)}) do |user, proj, extra|
    redirect "/github/#{user}/#{project}#{translate_file_links extra}"
  end

  get(%r{^/docs/([^/]+)(/?.*)}) do |lib, extra|
    redirect "/gems/#{lib}#{translate_file_links extra}"
  end
  
  get('/docs/?') { redirect '/github' }
  
  # Root URL redirection
  
  get '/' do
    redirect '/gems'
  end
  
  error do
    @page_title = "Unknown Error!"
    @error = "Something quite unexpected just happened. 
      Thanks to <a href='http://hoptoadapp.com'>Hoptoad</a> we know about the
      issue, but feel free to email <a href='mailto:lsegal@soen.ca'>someone</a>
      about it."
    notify_error
  end
end
