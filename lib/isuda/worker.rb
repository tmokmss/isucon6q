require 'sidekiq'

Sidekiq.configure_server do |config|
  config.redis = { 'db' => 1 }
end

class MyWorker
  include Sidekiq::Worker

  def perform(complexity)
    # html生成する
  end
end
