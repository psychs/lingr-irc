#-*- coding: utf-8 -*-
# Created by Satoshi Nakagawa.
# You can redistribute it and/or modify it under the Ruby's license or the GPL2.

require 'net/http'
require 'open-uri'
require 'cgi'
require 'logger'
require 'timeout'
require 'rubygems'
require 'json'


module Lingr

  class Member
    attr_reader :username, :name, :icon_url, :owner, :presence, :sessions
    
    def initialize(res)
      @username = res["username"]
      @name = res["name"]
      @icon_url = res["icon_url"]
      @owner = res["owner"]
      @presence = res["presence"]
      @sessions = []
    end
    
    def add_session(session)
      unless @sessions.index(session)
        @sessions << session
      end
    end
    
    def remove_session(session)
      @sessions.delete(session)
    end
    
    def inspect
      %Q|<#{self.class} #{username} #{name} #{sessions.size}>|
    end
  end
  
  
  class Room
    attr_reader :id, :name, :blurb, :public, :backlog, :members
    
    def initialize(res)
      @id = res["id"]
      @name = res["name"]
      @blurb = res["blurb"]
      @public = res["public"]
      @backlog = []
      @members = {}
      
      if msgs = res["messages"]
        msgs.each do |m|
          @backlog << Message.new(m["message"])
        end
      end
      
      if roster = res["roster"]
        if members = roster["members"]
          members.each do |u|
            m = Member.new(u)
            @members[m.username] = m
          end
        end
        
        if chatters = roster["chatters"]
          chatters.each do |c|
            username = c["username"]
            if m = @members[username]
              m.add_session(c["id"])
            end
          end
        end
      end
    end
    
    def add_member(member)
      @members[m.username] = member
    end
    
    def inspect
      %Q|<#{self.class} #{id}>|
    end
  end
  
  
  class Message
    attr_reader :id, :type, :nickname, :speaker_id, :public_session_id, :text, :timestamp, :mine
    
    def initialize(res)
      @id = res["id"]
      @type = res["type"]
      @nickname = res["nickname"]
      @speaker_id = res["speaker_id"]
      @public_session_id = res["public_session_id"]
      @text = res["text"]
      @timestamp = Time.iso8601(res["timestamp"])
      @mine = false
    end
    
    def decide_mine(my_public_session_id)
      @mine = @public_session_id == my_public_session_id
    end
    
    def inspect
      %Q|<#{self.class} #{speaker_id}: #{text}>|
    end
  end
  

  class APIError < Exception
    attr_reader :code, :detail

    def initialize(res)
      @code = res["code"]
      @detail = res["detail"]
    end

    def inspect
      %Q|<#{self.class} code="#{@code}", detail="#{@detail}">|
    end
  end
  
  
  class Connection

    URL_BASE = "http://lingr.com/api/"
    URL_BASE_OBSERVE = "http://lingr.com:8080/api/"
    REQUEST_TIMEOUT = 100
    RETRY_INTERVAL = 60
    
    attr_reader :user, :password, :auto_reconnect
    attr_reader :nickname, :public_id, :presence, :name, :username
    attr_reader :room_ids, :rooms
    attr_reader :connected_hooks, :error_hooks, :message_hooks, :join_hooks, :leave_hooks
    
    def initialize(user, password, auto_reconnect=true, logger=nil)
      @user = user
      @password = password
      @auto_reconnect = auto_reconnect
      @logger = logger
      @connected_hooks = []
      @error_hooks = []
      @message_hooks = []
      @join_hooks = []
      @leave_hooks = []
    end
    
    def start
      begin
        session_create
        get_rooms
        show_room(@room_ids.join(','))
        subscribe(@room_ids.join(','))
        
        @connected_hooks.each {|h| h.call(self) }
        
        loop do
          observe
        end
      rescue APIError => e
        raise e if e.code == "invalid_user_credentials"
        on_error(e)
        retry if @auto_reconnect
      rescue Exception => e
        on_error(e)
        retry if @auto_reconnect
      end
    end

    def session_create
      debug { "requesting session/create: #{@user}" }
      res = post("session/create", :user => @user, :password => @password)
      debug { "session/create response: #{res.inspect}" }
      @session = res["session"]
      @nickname = res["nickname"]
      @public_id = res["public_id"]
      @presence = res["presence"]
      if user = res["user"]
        @name = user["name"]
        @username = user["username"]
      end
      @rooms = {}
      res
    end

    def destroy_session
      debug { "requesting session/destroy_session" }
      res = post("session/destroy", :session => @session)
      debug { "session/destroy response: #{res.inspect}" }
      @session = nil
      @nickname = nil
      @public_id = nil
      @presence = nil
      @name = nil
      @username = nil
      @rooms = {}
      res
    rescue Exception => e
      log_error { "error in destroy_session: #{e.inspect}" }
    end
    
    def set_presence(presence)
      debug { "requesting session/set_presence: #{presence}" }
      res = post("session/set_presence", :session => @session, :presence => presence, :nickname => @nickname)
      debug { "session/set_presence response: #{res.inspect}" }
      res
    end

    def get_rooms
      debug { "requesting user/response" }
      res = get("user/get_rooms", :session => @session)
      debug { "user/get_rooms response: #{res.inspect}" }
      @room_ids = res["rooms"]
      res
    end

    def show_room(room_id)
      debug { "requesting room/show: #{room_id}" }
      res = get("room/show", :session => @session, :room => room_id)
      debug { "room/show response: #{res.inspect}" }
      
      if rooms = res["rooms"]
        rooms.each do |d|
          r = Room.new(d["room"])
          r.backlog.each do |m|
            m.decide_mine(@public_id)
          end
          @rooms[r.id] = r
        end
      end
      
      res
    end

    def subscribe(room_id)
      debug { "requesting room/subscribe: #{room_id}" }
      res = post("room/subscribe", :session => @session, :room => room_id)
      debug { "room/subscribe response: #{res.inspect}" }
      @counter = res["counter"]
      res
    end

    def unsubscribe(room_id)
      debug { "requesting room/unsubscribe: #{room_id}" }
      res = post("room/unsubscribe", :session => @session, :room => room_id)
      debug { "room/unsubscribe response: #{res.inspect}" }
      res
    end

    def say(room_id, text)
      debug { "requesting room/say: #{room_id} #{text}" }
      res = post("room/say", :session => @session, :room => room_id, :nickname => @nickname, :text => text)
      debug { "room/say response: #{res.inspect}" }
      res
    end

    def observe
      debug { "requesting event/observe: #{@counter}" }
      res = get("event/observe", :session => @session, :counter => @counter)
      debug { "observe response: #{res.inspect}" }
      @counter = res["counter"] if res["counter"]
      
      if events = res["events"]
        events.each do |event|
          if d = event["message"]
            if room = @rooms[d["room"]]
              m = Message.new(d)
              m.decide_mine(@public_id)
              @message_hooks.each {|h| h.call(self, room, m) }
            end
          elsif d = event["presence"]
            if room = @rooms[d["room"]]
              username = d["username"]
              id = d["public_session_id"]
              if status = d["status"]
                case status
                when "online"
                  first = false
                  unless m = room.members[username]
                    m = Member.new(d)
                    room.add_member(m)
                    first = true
                  end
                  m.add_session(id)
                  @join_hooks.each {|h| h.call(self, room, m, first) }
                when "offline"
                  if m = room.members[username]
                    m.remove_session(id)
                    @leave_hooks.each {|h| h.call(self, room, m) }
                  end
                end
              end
            end
          end
        end
      end
      
      res
    end

    private
    
    def on_error(e)
      log_error { "error: #{e.inspect}" }
      destroy_session
      @error_hooks.each {|h| h.call(self, e) }
      sleep RETRY_INTERVAL if @auto_reconnect
    end

    def get(path, params=nil)
      is_observe = path == "event/observe"
      url = is_observe ? URL_BASE_OBSERVE : URL_BASE
      url += path
      
      if params
        url += '?' + params.map{|k,v| "#{k}=#{CGI.escape(v.to_s)}"}.join('&')
      end
      
      res = nil
      begin
        timeout(REQUEST_TIMEOUT) do
          open(url) do |r|
            res = JSON.parse(r.read)
          end
        end
      rescue TimeoutError
        debug { "get request timed out: #{url}" }
        if is_observe
          res = { "status" => "ok" }
        else
          raise
        end
      end
      
      if res["status"] == "ok"
        res
      else
        raise APIError.new(res)
      end
    end
    
    def post(path, params=nil)
      url = URL_BASE + path
      if params
        url += '?' + params.map{|k,v| "#{k}=#{CGI.escape(v.to_s)}"}.join('&')
      end
      u = URI.parse(url)

      res = nil
      begin
        timeout(REQUEST_TIMEOUT) do
          http = Net::HTTP.new(u.host, u.port)
          response = http.post(u.path, u.query)
          res = JSON.parse(response.body)
        end
      rescue TimeoutError
        debug { "post request timed out: #{url}" }
        raise
      end
      
      if res["status"] == "ok"
        res
      else
        raise APIError.new(res)
      end
    end
    
    def debug(&block)
      @logger.debug(&block) if @logger
    end
    
    def log(&block)
      @logger.info(&block) if @logger
    end
    
    def log_error(&block)
      @logger.error(&block) if @logger
    end
    
  end
  
end
