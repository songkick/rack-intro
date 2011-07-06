# I recently wasted a ton of meeting time trying to communicate some patterns
# one can use building applications with [Rack][1], when what I *should* have done
# is write some code. This document is a brief absolute beginners guide to Rack
# and what you can do with it. Apologies for those parts that are already old
# hat for everyone.
#
# [1]: http://rack.rubyforge.org/
#
# # What is Rack?
#
# ![rack](http://rack.rubyforge.org/rack-logo.png)
#
# As its website will tell you:
#
# > Rack provides a minimal interface between webservers supporting Ruby and
# > Ruby frameworks.
#
# What this means is that Rack provides a bridge between Ruby web servers and
# application frameworks so that any application can easily be served with any
# web server. This has the side effect of making applications trivially
# composable.

# A Rack application is any Ruby object that responds to `call` by accepting a
# `Hash` representing the HTTP request environment and returning an `Array`
# containing a status code, a `Hash` of response headers, and an `Enumerable`
# response body. The simplest Rack app is just a `lambda`.
application = lambda do |env|
  [200, {'Content-Type' => 'text/plain'}, ['Hello, World']]
end

# Rack comes with a CLI program called `rackup` that lets you boot your app from
# a simple config file. In this file (called `config.ru`), we just load the
# application we want to run, and tell Rack to run it.
application = lambda do |env|
  [200, {'Content-Type' => 'text/plain'}, ['Hello, World']]
end

run application

# We can run this file using `rackup` and we get a website!
#
#     $ rackup config.ru
#     $ curl http://localhost:9292/
#     Hello, World
#
# `rackup` lets you specify the web server, port, environment, and various other
# things, for example:
#
#     $ rackup config.ru -s thin -p 8000 -E production

# Everything in the `config.ru` API and the `rackup` interface are also
# available through more object-y APIs in Ruby so it's easy to build up and run
# an application from anywhere in a Ruby program. For example this is how you'd
# run an application with [Thin][2] using the Ruby API.
# 
# [2]: http://code.macournoyer.com/thin/
#
Rack::Handler.get('thin').run(application, :Port => 8000)

# ## Middleware
#
# Because Rack establishes a convention that all applications expose the same
# API, it is easy to produce middleware - components that act as proxies between
# the web server and the application and can either send a response themselves,
# or delegate the call down the stack and optionally modify what comes back.

# When Rack instantiates a middleware, it passes a reference to the next item
# down the stack so we can delegate to it. As an example, let's say we want all
# our apps to respond to `GET /ping` so we can check they are up. This is
# orthogonal to the concerns of the application and can be implemented as
# middleware:
class Ping
  def initialize(app)
    @app = app
  end
  
  def call(env)
    if env['PATH_INFO'] == '/ping' and env['REQUEST_METHOD'] == 'GET'
      [200, {'Content-Type' => 'text/plain'}, ['OK']]
    else
      @app.call(env)
    end
  end
end

# If you like, you can use `Rack::Request` to wrap `env` in an object-based API
# that provides convenience methods for most HTTP stuff.
request = Rack::Request.new(env)
if request.path_info == '/ping' and request.get?
  [200, {'Content-Type' => 'text/plain'}, ['OK']]
end

# We can then insert this middleware in front of our application easily using
# `config.ru`. This configuration will cause Rack to build our stack by calling
# `Ping.new(application)`.
use Ping
run application

# You can use any number of middlewares in an application. People routinely use
# this to perform routing, logging, compression, data transformation and
# authentication. When you call `use`, the given class will be instantiated with
# a single object representing *everything* beneath it in the stack.

# Finally, the `rackup` DSL is available through the `Rack::Builder` class if
# you want to construct a Rack stack anywhere in your Ruby app. `Rack::Builder`
# creates a Rack application composed of the middlewares you specify, and you
# then use `Rack::Handler` to boot it.
stack = Rack::Builder.new do
  use Ping
  run application
end

# ## Why Rack?
#
# Rack is very widely deployed and supported in the Ruby community. Sinatra,
# Rails 3, and many other frameworks support it. There are dozens of middlewares
# you can install for common tasks, and Rack itself comes with many tools that
# make assembling applications a breeze.

# # Rack patterns

# I'm going to take a single example application with two controllers and show
# various ways you can build and configure it with Rack. Let's say we start with
# a Rails app that lets us create and retrieve artists and venues.

class ArtistsController
  def create ; end
  def show ; end
end

class VenuesController
  def create ; end
  def show ; end
end

# The routes for this simple application will be:
#
# * `POST /artists`
# * `GET /artists/:id`
# * `POST /venues`
# * `GET /venues/:id`

# In a Rails application, all your controllers are bundled up into a single Rack
# application, say `Songkick::Application`. You could create a load of different
# apps and distribute the controllers across them, but if we use Rack directly
# we buy a little more freedom. Let's start by modelling our routes directly in
# Sinatra.
#
# This is a complete, valid `config.ru` file. We can run it and it does what you
# would expect:
#
#     $ curl http://localhost:9292/artists/5
#     Artist number 5
#     $ curl -X POST http://localhost:9292/venues -H 'Content-Length: 0'
#     Venue created

require 'sinatra'

post '/artists' do
  'Artist created'
end

get '/artists/:id' do
  "Artist number #{params[:id]}"
end

post '/venues' do
  'Venue created'
end

get '/venue/:id' do
  "Venue number #{params[:id]}"
end

run Sinatra::Application


# ## Delegation using Rack::URLMap

# In our Sinatra example, we still have all our controllers bundled into a
# single application. What can do instead it split them into two applications
# and place a router in front.
#
# With this setup, `Artists` and `Venues` are now two distinct Rack applications
# and could trivially be run as separate processes. Notice how the routing
# within each app is only concerned with the paths within that resource's
# namespace; the namespace itself is handled by the router further up the stack.
# When using `map`, Rack will modify `PATH_INFO` so that downstream apps only
# have to route based on the parts of the path the router ignored.

class Artists < Sinatra::Base
  post '/' do
    'Artist created'
  end
  get '/:id' do
    "Artist number #{params[:id]}"
  end
end

class Venues < Sinatra::Base
  post '/' do
    'Venue created'
  end
  get '/:id' do
    "Venue number #{params[:id]}"
  end
end

map '/artists' do
  run Artists
end

map '/venues' do
  run Venues
end

# To emphasize the separation, we can bypass the `rackup` DSL and use the
# `Rack::URLMap` class ourselves. A `Rack::URLMap` instance is *itself* a Rack
# application, and so you can build trees of these to route your traffic.

application = Rack::URLMap.new(
  '/artists' => Artists,
  '/venues'  => Venues
)
run application

# ## Manual delegation using call()

# You can even build your own router to do whatever arbitrary logic you like.
# For example, let's build an app that routes `POST` requests to `Artists` and
# `GET` requests to `Venues`. This setup responds as follows:
#
#     $ curl -X POST http://localhost:9292/ -H 'Content-Length: 0'
#     Artist created
#     $ curl http://localhost:9292/99
#     Venue number 99

router = lambda do |env|
  case env['REQUEST_METHOD']
    when 'POST' then Artists.call(env)
    when 'GET'  then Venues.call(env)
  end
end

run router

# Finally you can just use `run Artists` or `run Venues` if you just want to run
# *one* of these controllers in a single process.

# ## Layouts as middleware

# If you want to split an app into many pieces but still want to share a layout
# between them, this can easily be done with middleware. Let's make a middleware
# That renders a layout and delegates to the underlying app to get the page.
#
# The middleware starts out by making a call to the application to fetch a page,
# an extracts the response body (which all we can assume is that this responds
# to `each`). It then renders a complete page by combining the page with an ERB
# template for the layout.
#
# Then we just need a layout template that pipes the response body into the
# middle of the document.
#
#     <!doctype html>
#     <html>
#       <head>
#         <title>My awesome Rack app</title>
#       </head>
#       <body>
#         <% @page.each do |fragment| %><%= fragment %><% end %>
#       </body>
#     </html>
class Layout
  def initialize(app, layout_template)
    @app, @layout_template = app, layout_template
  end
  
  def call(env)
    page_body = @app.call(env)[2]
    body = Page.new(page_body, @layout_template).render
    [200, {'Content-Type' => 'text/html'}, [body]]
  end
  
  class Page
    def initialize(page, layout_template)
      @page, @layout_template = page, layout_template
    end
    
    def render
      template = ERB.new(File.read(@layout_template))
      template.result(binding)
    end
  end
end

# Let's run our Sinatra app using this middleware:
#
#     $ curl http://localhost:9292/artists/3000
#     <!doctype html>
#     <html>
#       <head>
#         <title>My awesome Rack app</title>
#       </head>
#       <body>
#         Artist number 3000
#       </body>
#     </html>

application = Rack::URLMap.new(
  '/artists' => Artists,
  '/venues'  => Venues
)

use Layout, 'views/layouts/layout.erb'
run application

# You can also apply middleware selectively to different parts of the stack. For
# example if we only wanted to use this layout for venues, we could do this:
#
#     $ curl http://localhost:9292/artists/3000
#     Artist number 3000
#
#     $ curl http://localhost:9292/venues/3000
#     <!doctype html>
#     <html>
#       <head>
#         <title>My awesome Rack app</title>
#       </head>
#       <body>
#         Venue number 3000
#       </body>
#     </html>
#
# You can imagine how we might use this to compose pages from various backends,
# for example to mimick an Nginx SSI setup to make it easy to boot a set of
# applications for development.

map '/artists' do
  run Artists
end

map '/venues' do
  use Layout, 'views/layouts/layout.erb'
  run Venues
end

# ## Turn anything into a Rack app with Rack::Proxy

# `Rack::Proxy` is a third-party add-on (`gem install rack-proxy`) that lets you
# wrap a Rack object around any web service. This is useful for:
#
# * Bringing third-party apps and other languages into your stack
# * Using `Rack::Test` against non-Ruby apps
# * Doing evil stuff to pages from third parties with Ruby!

# For example, here's a Rack-compatible version of Songkick. (In practise
# proxying arbitrary websites is not quite this simple but it's not terribly
# difficult either.)

require 'rack/proxy'

class Songkick < Rack::Proxy
  def rewrite_env(env)
    env['HTTP_HOST'] = 'www.songkick.com'
    env['SERVER_NAME'] = 'www.songkick.com'
    env['SERVER_PORT'] = '80'
    env
  end
end

run Songkick.new

# This mix of middlewares, routers and proxies is very powerful and makes it
# easy to change the layout of an application without too much work.

# # Testing with Rack::Test

# `Rack::Test` (`gem install rack-test`) is an API for testing Rack apps. It is
# very useful for specifying protocol-level details of application responses,
# and can also be used as a backend for high-level testing APIs like Capybara.
# Using it is dead simple, and with a little help from `Rack::Proxy` you can use
# it to test just about anything.
#
# Here's a complete spec for testing our ping middleware.

require 'rack/test'

describe Ping do
  include Rack::Test::Methods
  let(:app) { Ping.new(nil) }
  
  describe "GET /ping" do
    before { get "/ping" }
    
    it "responds with 200 OK" do
      last_response.status.should == 200
      last_response.body.should == "OK"
    end
  end
end

# # Bonus round: async apps

# You've probably heard that Node is awesome because everything is asynchronous.
# Well we can do the same thing using some Rack extensions in Thin. Here's a
# basic async Thin app.
#
# This is useful if your backend takes a long time to reply, and is async itself.
# Thin is single-threaded so any long-blocking code will block the event loop,
# meaning Thin cannot process other concurrent requests.
#
# There are some frameworks that take advantage of this, such as [Cramp][3],
# [Async Sinatra][4] and [Async Rack][5].
#
# [3]: http://m.onkey.org/introducing-cramp
# [4]: http://rubygems.org/gems/async_sinatra
# [5]: https://rubygems.org/gems/async-rack

require 'eventmachine'

class AsyncApp
  class ResponseBody
    include EM::Deferrable
    alias :each :callback
  end
  
  def call(env)
    callback = env['async.callback']            # Thin's async callback
    response = ResponseBody.new                 # Deferred response object
    headers  = {'Content-Type' => 'text/html'}
    callback.call([200, headers, response])     # Send the headers right now
    EM.add_timer(5) do
      response.succeed('Hello!')                # Send the body in 5 seconds
    end
    [-1, {}, []]                                # Async response
  end
end

run AsyncApp.new

