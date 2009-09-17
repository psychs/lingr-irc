#-*- coding: utf-8 -*-
# Created by Satoshi Nakagawa.
# You can redistribute it and/or modify it under the Ruby's license or the GPL2.

require 'socket'
require File.dirname(__FILE__) + '/lingr.rb'


module LingrIRCGateway
  
  class Server
    def initialize(port)
      @port = port
    end

    def start
      @server = TCPServer.open(@port)
      loop do
        Client.new(@server.accept)
      end
    end
  end
  
  
  class Client
    def initialize(socket)
      @socket = socket
      process
    end
    
    def process
      while line = @socket.gets
        case line.chomp
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
        end
      end
    end
    
    private
    
    def on_user(param)
      params = param.split(' ', 4)
      realname = params[3]
      realname = $~.post_match if realname =~ /^:/
      @show_backlog = realname =~ /backlog/
      @show_time = realname =~ /time/
      
      @lingr = Lingr::Connection.new(@user, @password)

      @lingr.connected_hooks << lambda do |sender|
        begin
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
                s = "#{user_prefix(m.speaker_id)} NOTICE ##{room.id} :#{m.text}"
                if @show_time
                  time = m.timestamp
                  time.localtime
                  s << " (#{time.strftime('%m/%d %H:%M')})"
                end
                send(s)
              end
            end
            room.backlog.clear
          end
        rescue => e
          p e
        end
      end

      @lingr.error_hooks << lambda do |sender, error|
        begin
          p error
          send(%Q|ERROR :Closing Link: #{@user}!#{@user}@lingr.com ("#{error.inspect}")|)
        rescue => e
          p e
        end
      end

      @lingr.message_hooks << lambda do |sender, room, message|
        begin
          unless message.mine
            send("#{user_prefix(message.speaker_id)} PRIVMSG ##{room.id} :#{message.text}")
          end
        rescue => e
          p e
        end
      end

      @lingr.join_hooks << lambda do |sender, room, member, first|
        begin
          if first
            send("#{user_prefix(member.username)} JOIN ##{room.id}")
          end
        rescue => e
          p e
        end
      end

      Thread.new do
        begin
          @lingr.start
        rescue Lingr::Error => e
          p e
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
    
    def send(line)
      @socket.puts(line)
    end
    
    def reply(num, line)
      s = sprintf(":lingr %03d #{@user} #{line}", num)
      send(s)
    end
    
    def my_prefix
      ":#{@user}!#{@user}@lingr.com"
    end
    
    def user_prefix(user)
      ":#{user}!#{user}@lingr.com"
    end
    
  end
  
end


if __FILE__ == $0
  c = LingrIRCGateway::Server.new(26667)
  c.start
end
