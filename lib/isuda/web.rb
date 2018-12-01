require 'digest/sha1'
require 'json'
require 'net/http'
require 'uri'

require 'erubis'
require 'mysql2'
require 'mysql2-cs-bind'
require 'rack/utils'
require 'sinatra/base'
require 'tilt/erubis'
require 'redis'

require 'rack-mini-profiler'
require 'flamegraph'

module Isuda
  class Web < ::Sinatra::Base
    use Rack::MiniProfiler
    enable :protection
    enable :sessions

    set :erb, escape_html: true
    set :public_folder, File.expand_path('../../../../public', __FILE__)
    set :db_user, ENV['ISUDA_DB_USER'] || 'root'
    set :db_password, ENV['ISUDA_DB_PASSWORD'] || ''
    set :dsn, ENV['ISUDA_DSN'] || 'dbi:mysql:db=isuda'
    set :session_secret, 'tonymoris'
    set :isupam_origin, ENV['ISUPAM_ORIGIN'] || 'http://localhost:5050'
    set :isutar_origin, ENV['ISUTAR_ORIGIN'] || 'http://localhost:5001'

    set :db_user_star, ENV['ISUTAR_DB_USER'] || 'root'
    set :db_password_star, ENV['ISUTAR_DB_PASSWORD'] || ''
    set :dsn_star, ENV['ISUTAR_DSN'] || 'dbi:mysql:db=isutar'

    configure :development do
      require 'sinatra/reloader'

      register Sinatra::Reloader
    end

    set(:set_name) do |value|
      condition {
        user_id = session[:user_id]
        if user_id
          user = db.xquery(%| select name from user where id = ? |, user_id).first
          @user_id = user_id
          @user_name = user[:name]
          halt(403) unless @user_name
        end
      }
    end

    set(:authenticate) do |value|
      condition {
        halt(403) unless @user_id
      }
    end

    helpers do
      def db
        Thread.current[:db] ||=
          begin
            _, _, attrs_part = settings.dsn.split(':', 3)
            attrs = Hash[attrs_part.split(';').map {|part| part.split('=', 2) }]
            mysql = Mysql2::Client.new(
              username: settings.db_user,
              password: settings.db_password,
              database: attrs['db'],
              encoding: 'utf8mb4',
              init_command: %|SET SESSION sql_mode='TRADITIONAL,NO_AUTO_VALUE_ON_ZERO,ONLY_FULL_GROUP_BY'|,
            )
            mysql.query_options.update(symbolize_keys: true)
            mysql
          end
      end

      def db_star
        Thread.current[:db_star] ||=
          begin
            _, _, attrs_part = settings.dsn_star.split(':', 3)
            attrs = Hash[attrs_part.split(';').map {|part| part.split('=', 2) }]
            mysql = Mysql2::Client.new(
              username: settings.db_user_star,
              password: settings.db_password_star,
              database: attrs['db'],
              encoding: 'utf8mb4',
              init_command: %|SET SESSION sql_mode='TRADITIONAL,NO_AUTO_VALUE_ON_ZERO,ONLY_FULL_GROUP_BY'|,
            )
            mysql.query_options.update(symbolize_keys: true)
            mysql
          end
      end

      def register(name, pw)
        chars = [*'A'..'~']
        salt = 1.upto(20).map { chars.sample }.join('')
        salted_password = encode_with_salt(password: pw, salt: salt)
        db.xquery(%|
          INSERT INTO user (name, salt, password, created_at)
          VALUES (?, ?, ?, NOW())
        |, name, salt, salted_password)
        db.last_id
      end

      def encode_with_salt(password: , salt: )
        Digest::SHA1.hexdigest(salt + password)
      end

      def is_spam_content(content)
        isupam_uri = URI(settings.isupam_origin)
        res = Net::HTTP.post_form(isupam_uri, 'content' => content)
        validation = JSON.parse(res.body)
        validation['valid']
        ! validation['valid']
      end

      def fetch_all_keyword_pattern
        keywords = db.xquery(%| select keyword from entry order by keyword_length desc |)
        keywords.map {|k| Regexp.escape(k[:keyword]) }.join('|')
      end

      def latest_entry_id
        @latest_entry_id ||= db.xquery(%| select id from entry order by id desc limit 1 |).first[:id]
      end

      def htmlify(entry_id)
        res = db.xquery(%|select last_checked_entry_id, htmlified from entry where id = ?|, entry_id).first
        last_checked_entry_id = res[:last_checked_entry_id]
        htmlified = res[:htmlified]
        return htmlified if latest_entry_id == last_checked_entry_id

        if htmlified.nil?
          htmlified = db.xquery(%| select description from entry where id = ? |, entry_id).first[:description]
        end

        keywords = db.xquery(%|select keyword from entry where id between ? and ? order by keyword_length desc |, last_checked_entry_id, latest_entry_id);
        pattern = keywords.map {|k| Regexp.escape(k[:keyword]) }.join('|')
        kw2hash = {}
        hashed_content = htmlified.gsub(/(#{pattern})/) {|m|
          matched_keyword = $1
          "isuda_#{Digest::SHA1.hexdigest(matched_keyword)}".tap do |hash|
            kw2hash[matched_keyword] = hash
          end
        }
        escaped_content = Rack::Utils.escape_html(hashed_content)
        kw2hash.each do |(keyword, hash)|
          keyword_url = url("/keyword/#{Rack::Utils.escape_path(keyword)}")
          anchor = '<a href="%s">%s</a>' % [keyword_url, Rack::Utils.escape_html(keyword)]
          escaped_content.gsub!(hash, anchor)
        end

        db.xquery(%| update entry set htmlified = ?, last_checked_entry_id = ? where = ? |, escaped_content, latest_entry_id, entry_id)

        escaped_content.gsub(/\n/, "<br />\n")
      end

      def uri_escape(str)
        Rack::Utils.escape_path(str)
      end

      def load_stars(keyword)
        stars = db_star.xquery(%| select * from star where keyword = ? |, keyword).to_a
        body = JSON.generate(stars: stars)
        stars_res = JSON.parse(body)
        stars_res['stars']
      end

      def redirect_found(path)
        redirect(path, 302)
      end
    end

    get '/initialize' do
      db.xquery(%| DELETE FROM entry WHERE id > 7101 |)
      db_star.xquery('TRUNCATE star')

      db.xquery(%| update entry set htmlified = null, last_checked_entry_id = 0 |)

      content_type :json
      JSON.generate(result: 'ok')
    end

    get '/', set_name: true do
      per_page = 10
      page = (params[:page] || 1).to_i

      entries = db.xquery(%|
        SELECT id, keyword FROM entry
        ORDER BY updated_at DESC
        LIMIT #{per_page}
        OFFSET #{per_page * (page - 1)}
      |)
      #pattern = fetch_all_keyword_pattern
      entries.each do |entry|
        entry[:html] = htmlify(entry[:id])
        entry[:stars] = load_stars(entry[:keyword])
      end

      total_entries = db.xquery(%| SELECT count(id) AS total_entries FROM entry |).first[:total_entries].to_i

      last_page = (total_entries.to_f / per_page.to_f).ceil
      from = [1, page - 5].max
      to = [last_page, page + 5].min
      pages = [*from..to]

      locals = {
        entries: entries,
        page: page,
        pages: pages,
        last_page: last_page,
      }
      erb :index, locals: locals
    end

    get '/robots.txt' do
      halt(404)
    end

    get '/register', set_name: true do
      erb :register
    end

    post '/register' do
      name = params[:name] || ''
      pw   = params[:password] || ''
      halt(400) if (name == '') || (pw == '')

      user_id = register(name, pw)
      session[:user_id] = user_id

      redirect_found '/'
    end

    get '/login', set_name: true do
      locals = {
        action: 'login',
      }
      erb :authenticate, locals: locals
    end

    post '/login' do
      name = params[:name]
      user = db.xquery(%| select * from user where name = ? |, name).first
      halt(403) unless user
      halt(403) unless user[:password] == encode_with_salt(password: params[:password], salt: user[:salt])

      session[:user_id] = user[:id]

      redirect_found '/'
    end

    get '/logout' do
      session[:user_id] = nil
      redirect_found '/'
    end

    post '/keyword', set_name: true, authenticate: true do
      keyword = params[:keyword] || ''
      halt(400) if keyword == ''
      description = params[:description]
      halt(400) if is_spam_content(description) || is_spam_content(keyword)

      bound = [@user_id, keyword, description] * 2
      db.xquery(%|
        INSERT INTO entry (author_id, keyword, description, created_at, updated_at)
        VALUES (?, ?, ?, NOW(), NOW())
        ON DUPLICATE KEY UPDATE
        author_id = ?, keyword = ?, description = ?, updated_at = NOW()
      |, *bound)

      redirect_found '/'
    end

    get '/keyword/:keyword', set_name: true do
      keyword = params[:keyword] or halt(400)

      entry = db.xquery(%| select id, keyword from entry where keyword = ? |, keyword).first or halt(404)
      entry[:stars] = load_stars(entry[:keyword])
      #pattern = fetch_all_keyword_pattern
      entry[:html] = htmlify(entry[:id])

      locals = {
        entry: entry,
      }
      erb :keyword, locals: locals
    end

    post '/keyword/:keyword', set_name: true, authenticate: true do
      keyword = params[:keyword] or halt(400)
      is_delete = params[:delete] or halt(400)

      unless db.xquery(%| SELECT id FROM entry WHERE keyword = ? |, keyword).first
        halt(404)
      end

      db.xquery(%| DELETE FROM entry WHERE keyword = ? |, keyword)

      redirect_found '/'
    end

    post '/stars' do
      keyword = params[:keyword] or halt(400)

      entry = db.xquery(%| select * from entry where keyword = ? |, keyword).first or halt(404)

      user_name = params[:user]
      db_star.xquery(%|
        INSERT INTO star (keyword, user_name, created_at)
        VALUES (?, ?, NOW())
      |, keyword, user_name)

      content_type :json
      JSON.generate(result: 'ok')
    end
  end
end
