#-*- coding: utf-8 -*-
# Created by Satoshi Nakagawa.
# You can redistribute it and/or modify it under the Ruby's license or the GPL2.

require 'socket'
require 'logger'
require File.dirname(__FILE__) + '/lingr.rb'


module LingrIRCGateway
  
  PRIVMSG = "PRIVMSG"
  NOTICE = "NOTICE"
  
  class Server
    def initialize(port, backlog_count=30, logger=nil, api_key=nil)
      @port = port
      @backlog_count = backlog_count
      @logger = logger
      @api_key = api_key
    end

    def start
      @server = TCPServer.open(@port)
      log { "started Lingr IRC gateway at localhost:#{@port}" }
      loop do
        c = Client.new(@server.accept, @backlog_count, @logger, @api_key)
        Thread.new do
          c.process
        end
      end
    end
    
    def log(&block)
      @logger.info(&block) if @logger
    end
  end
  
  
  class Client
    def initialize(socket, backlog_count, logger=nil, api_key=nil)
      @socket = socket
      @backlog_count = backlog_count
      @logger = logger
      @api_key = api_key
    end
    
    def process
      while line = @socket.gets
        line.chomp!
        log { "received from IRC client: #{line}" }
        case line
        when /^PASS\s+/i
          @password = $~.post_match
        when /^NICK\s+/i
          @user = $~.post_match
        when /^USER\s+/i
          on_user($~.post_match)
        when /^PRIVMSG\s+/i, /^NOTICE\s+/i
          s = $~.post_match
          on_privmsg(*s.split(/\s+/, 2))
        when /^WHOIS\s+/i
          on_whois($~.post_match)
        when /^PING\s+/i
          on_ping($~.post_match)
        when /^QUIT/i
          on_quit
        end
      end
    rescue => e
      log_error { "error in IRC client read loop: #{e.inspect}" }
      terminate
    end
    
    private
    
    def on_user(param)
      params = param.split(' ', 4)
      realname = params[3]
      realname = $~.post_match if realname =~ /^:/
      @show_backlog = realname =~ /backlog/
      @show_time = realname =~ /time/
      
      log { "connecting to Lingr: #{@user}" }
      
      @lingr = Lingr::Connection.new(@user, @password, @backlog_count, true, @logger, @api_key)

      @lingr.connected_hooks << lambda do |sender|
        begin
          log { "connected to Lingr" }
          
          reply(1, ":Welcome to Lingr!")
          reply(376, ":End of MOTD.")

          @lingr.rooms.each do |k, room|
            send("#{my_prefix} JOIN ##{room.id}")
            
            # show room name as topic
            reply(332, "##{room.id} :#{room.name}")
            
            # show names list
            names = room.members.map{|k,m| "#{m.owner ? '@' : ''}#{m.username}" }.join(' ')
            reply(353, "= ##{room.id} :#{names}")
            reply(366, "##{room.id} :End of NAMES list.")
            
            # show backlog
            if @show_backlog
              room.backlog.each do |m|
                send_text(m, room, NOTICE)
              end
            end
            room.backlog.clear
          end
        rescue => e
          log_error { "gateway exception in connected event: #{e.inspect}" }
          terminate
        end
      end

      @lingr.error_hooks << lambda do |sender, error|
        begin
          log { "received error from Lingr: #{error.inspect}" }
          send(%Q[ERROR :Closing Link: #{@user}!#{@user}@lingr.com ("#{error.inspect}")])
          terminate
        rescue => e
          log_error { "gateway exception in error event: #{e.inspect}" }
          terminate
        end
      end

      @lingr.message_hooks << lambda do |sender, room, message|
        begin
          log { "received message from Lingr: #{room.id} #{message.inspect}" }
          unless message.mine
            send_text(message, room, message.type == 'bot' ? NOTICE : PRIVMSG)
          end
        rescue => e
          log_error { "gateway exception in message event: #{e.inspect}" }
          terminate
        end
      end

      @lingr.join_hooks << lambda do |sender, room, member|
        begin
          log { "received join from Lingr: #{room.id} #{member.username}" }
        rescue => e
          log_error { "gateway exception in join event: #{e.inspect}" }
          terminate
        end
      end

      @worker = Thread.new do
        begin
          @lingr.start
        rescue Exception => e
          log_error { "Lingr connection exception: #{e.inspect}" }
          terminate
        end
      end
    end
    
    def on_privmsg(chan, text)
      chan = chan[1..-1]
      text = $~.post_match if text =~ /^:/
      @lingr.say(chan, text)
    end
    
    def on_whois(param)
      nick = param.split(' ')[0]
      
      rooms = []
      member = nil
      @lingr.rooms.each do |k,r|
        if m = r.members[nick]
          member = m
          rooms << [r,m]
        end
      end
      
      if member
        reply(311, "#{nick} #{nick} lingr.com * :#{member.name}")
        chans = rooms.map {|e| "#{e[1].owner ? '@' : ''}##{e[0].id}" }.join(' ')
        reply(319, "#{nick} :#{chans}")
        reply(312, "#{nick} lingr.com :San Francisco, US")
        reply(318, "#{nick} lingr.com :End of WHOIS list.")
      end
    end

    def on_ping(server)
      send("PONG #{server}")
    end
    
    def on_ping(text)
      send("#{my_prefix} PONG ##{text}")
    end
    
    def on_quit
      send(%Q[ERROR :Closing Link: #{@user}!#{@user}@lingr.com ("Client quit")])
      terminate
    end
    
    def terminate
      @socket.close
      @worker.terminate
    rescue Exception
    end
    
    def send(line)
      @socket.puts(line)
    end
    
    def reply(num, line)
      s = sprintf(":lingr %03d #{@user} #{line}", num)
      send(s)
    end
    
    def send_text(message, room, cmd)
      timestr = ""
      if cmd == NOTICE
        if @show_time
          time = message.timestamp
          time.localtime
          timestr = " (#{time.strftime('%m/%d %H:%M')})"
        end
      end
      
      lines = message.text.split(/\r?\n/)
      lines.each do |line|
        send("#{user_prefix(message.speaker_id)} #{cmd} ##{room.id} :#{line.chomp}#{timestr}")
      end
    end
    
    def my_prefix
      ":#{@user}!#{@user}@lingr.com"
    end
    
    def user_prefix(user)
      ":#{user}!#{user}@lingr.com"
    end
    
    def log(&block)
      @logger.info(&block) if @logger
    end
    
    def log_error(&block)
      @logger.error(&block) if @logger
    end
    
  end
  
end


if __FILE__ == $0
  backlog_count = 30
  logger = nil
  #logger = Logger.new(STDERR)
  api_key = nil
  c = LingrIRCGateway::Server.new(26667, backlog_count, logger, api_key)
  c.start
end
