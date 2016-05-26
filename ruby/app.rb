require 'sinatra/base'
require 'json'
require 'mysql2-cs-bind'
require 'digest/sha2'
require 'dalli'
require 'rack/session/dalli'
require 'erubis'
require 'tempfile'
require 'redis'
require 'redcarpet'

class Isucon3App < Sinatra::Base
  $stdout.sync = true
  use Rack::Session::Cookie, key: 'isucon_session'

  helpers do
    set :erb, :escape_html => true

    def connection
      return $mysql if $mysql
      config = JSON.parse(IO.read(File.dirname(__FILE__) + "/../config/#{ ENV['ISUCON_ENV'] || 'local' }.json"))['database']
      $mysql = Mysql2::Client.new(
        :host => config['host'],
        :port => config['port'],
        :username => config['username'],
        :password => config['password'],
        :database => config['dbname'],
        :reconnect => true,
      )
    end

    def get_user
      user_id = session["user_id"]

      if user_id
        get_user_by_id(user_id)
      else
        {}
      end
    end

    def get_user_by_id(id)
      user = redis.get("user-#{id}")

      if user.nil?
        connection.xquery("SELECT * FROM users").each do |row|
          redis.set("user-#{row['id']}", row["username"])
        end
        user = redis.get("user-#{id}")
      end

      headers "Cache-Control" => "private"
      { "id" => id, "username" => user }
    end

    def require_user(user)
      unless user["username"]
        redirect "/"
        halt
      end
    end

    def gen_markdown(md)
      return markdown.render(md)
    end

    def total_memo_page
      total = redis.get('memo-total-count')
      return total if total

      total = connection.xquery('SELECT count(*) AS c FROM memos WHERE is_private=0').first["c"]
      redis.set('memo-total-count', total)
      total
    end

    def memo_pages(page = 0)
      memos = redis.get("memos-page-#{page}")

      if memos
        JSON.parse(memos)
      else
        memos = connection.query("SELECT m.*, username FROM memos m JOIN users u ON m.user = u.id WHERE is_private=0 ORDER BY created_at DESC, id DESC LIMIT 100 OFFSET #{page * 100}")
        redis.set("memo-page-#{page}", memos.to_a.to_json)
        memos
      end
    end

    def clear_page_cache
      redis.keys.select{ |key| key.match(/^memo/) }.each{ |key| redis.del(key) }
    end

    def anti_csrf
      if params["sid"] != session["token"]
        halt 400, "400 Bad Request"
      end
    end

    def url_for(path)
      scheme = request.scheme
      if (scheme == 'http' && request.port == 80 ||
          scheme == 'https' && request.port == 443)
        port = ""
      else
        port = ":#{request.port}"
      end
      base = "#{scheme}://#{request.host}#{port}#{request.script_name}"
      "#{base}#{path}"
    end

    def redis
      $redis ||= Redis.new
    end

    def markdown
      $markdown ||= Redcarpet::Markdown.new(Redcarpet::Render::HTML.new)
    end
  end

  get '/' do
    erb :index, :layout => :base, :locals => {
      :memos => memo_pages,
      :page  => 0,
      :total => total_memo_page,
      :user  => get_user,
    }
  end

  get '/recent/:page' do
    page  = params["page"].to_i
    memos = memo_pages(page)

    if memos.count == 0
      halt 404, "404 Not Found"
    end

    erb :index, :layout => :base, :locals => {
      :memos => memos,
      :page  => page,
      :total => total_memo_page,
      :user  => get_user,
    }
  end

  post '/signout' do
    user = get_user
    require_user(user)
    anti_csrf

    session.destroy
    redirect "/"
  end

  get '/signin' do
    user = get_user
    erb :signin, :layout => :base, :locals => {
      :user => user,
    }
  end

  post '/signin' do
    mysql = connection

    username = params[:username]
    password = params[:password]
    user = mysql.xquery('SELECT id, username, password, salt FROM users WHERE username=?', username).first
    if user && user["password"] == Digest::SHA256.hexdigest(user["salt"] + password)
      session.clear
      session["user_id"] = user["id"]
      session["token"] = Digest::SHA256.hexdigest(Random.new.rand.to_s)
      mysql.xquery("UPDATE users SET last_access=now() WHERE id=?", user["id"])
      redirect "/mypage"
    else
      erb :signin, :layout => :base, :locals => {
        :user => {},
      }
    end
  end

  get '/mypage' do
    user  = get_user
    require_user(user)

    erb :mypage, :layout => :base, :locals => {
      :user  => user,
      :memos => connection.xquery('SELECT id, content, is_private, created_at, updated_at FROM memos WHERE user=? ORDER BY created_at DESC', user["id"]),
    }
  end

  get '/memo/:memo_id' do
    mysql = connection
    user  = get_user

    memo = mysql.xquery('SELECT id, user, content, is_private, created_at, updated_at FROM memos WHERE id=?', params[:memo_id]).first
    unless memo
      halt 404, "404 Not Found"
    end
    if memo["is_private"] == 1
      if user["id"] != memo["user"]
        halt 404, "404 Not Found"
      end
    end
    memo["username"] = get_user_by_id(memo["user"])["username"]
    memo["content_html"] = gen_markdown(memo["content"])
    if user["id"] == memo["user"]
      cond = ""
    else
      cond = "AND is_private=0"
    end
    results = mysql.xquery("SELECT * FROM memos WHERE user=? #{cond} ORDER BY created_at", memo["user"])
    older = mysql.xquery("SELECT * FROM memos WHERE user = ? #{cond} AND created_at < ? ORDER BY created_at LIMIT 1", memo["user"], memo["created_at"]).first
    newer = mysql.xquery("SELECT * FROM memos WHERE user = ? #{cond} AND created_at > ? ORDER BY created_at LIMIT 1", memo["user"], memo["created_at"]).first

    erb :memo, :layout => :base, :locals => {
      :user  => user,
      :memo  => memo,
      :older => older,
      :newer => newer,
    }
  end

  post '/memo' do
    mysql = connection
    user  = get_user
    require_user(user)
    anti_csrf

    mysql.xquery(
      'INSERT INTO memos (user, content, is_private, created_at, title) VALUES (?, ?, ?, ?, ?)',
      user["id"],
      params["content"],
      params["is_private"].to_i,
      Time.now,
      params["content"].split("\n").first
    )
    clear_page_cache
    memo_id = mysql.last_id
    redirect "/memo/#{memo_id}"
  end

  run! if app_file == $0
end
