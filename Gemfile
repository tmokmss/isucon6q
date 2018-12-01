source 'https://rubygems.org'

ruby File.read('.ruby-version').strip

gem 'erubis'
gem 'mysql2'
gem 'mysql2-cs-bind'
gem 'sinatra'
gem 'unicorn'

group :development do
  gem 'foreman'
  gem 'sinatra-contrib', require: nil
end

group :development, :test do
 gem 'ruby-debug-ide'
 gem 'debase'
end

gem 'rack-mini-profiler'
# For memory profiling
gem 'memory_profiler'

# For call-stack profiling flamegraphs
gem 'flamegraph'
gem 'stackprof'

