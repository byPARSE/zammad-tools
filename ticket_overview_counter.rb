#!/usr/bin/env ruby
# encoding: utf-8

################################################################################
# Zammad Overview Ticket-Counter with top 3 analysis
#
# Description:
#   This script counts tickets from all agent views across all overviews and
#   displays the top 3 results. The aim is to evaluate the overviews and get
#   an idea of the server load that individual overviews can generate.
#
# USE AT YOUR OWN RISK! NOT COVERED BY ZAMMAD SUPPORT!
#
# Author: Tobias Siudak
# Version: 1.0.0
# Date: 2026-06-10
# License: MIT License
#
# Repository: https://github.com/byPARSE/zammad-tools
# Issues: https://github.com/byPARSE/zammad-tools/issues
#
# Requirements:
#   - Running Zammad instance as package installation
#   - Local Zammad-User have to have read+execution permissions on the script
#
# Usage:
#   zammad run rails r ticket_overview_counter.rb
#
# ATTENTION!:
# The script can generate heavy load on your Zammad server!
# Run this script only if you understand what it is doing and outside agents worktimes!
# Cause of counting the tickets as all agents in a system this run can take a long
# time when you have many agents!
#
################################################################################
#
# MIT License
#
# Copyright (c) 2026 Tobias Siudak
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
################################################################################









# Progressbar-Hilfsmethode
def progress_bar(current, total, label = "", width = 40)
    percentage = (current.to_f / total * 100).round(1)
    filled     = (current.to_f / total * width).round
    bar        = "█" * filled + "░" * (width - filled)
    print "\r[#{bar}] #{percentage}% (#{current}/#{total}) #{label.ljust(40)}"
    $stdout.flush
end

puts "=" * 60
puts "Top 3 Übersichten mit den meisten Tickets"
puts "(Analyse über alle Agenten)"
puts "=" * 60
puts

agents    = User.with_permissions('ticket.agent').to_a
overviews = Overview.all.to_a

total_steps = agents.size * overviews.size
current     = 0

puts "👥 Agenten gefunden:    #{agents.size}"
puts "📋 Übersichten gefunden: #{overviews.size}"
puts "🔢 Gesamt-Iterationen:   #{total_steps}"
puts

# Ergebnis-Hash: overview_id => { name, link, max_count, best_agent }
best = {}

agents.each do |agent|
    overviews.each do |overview|
        current += 1
        progress_bar(current, total_steps, "#{agent.login} / #{overview.name}")

        begin
            result       = Ticket.selectors(overview.condition, { current_user: agent })
            ticket_count = result[0].to_i

            if !best[overview.id] || ticket_count > best[overview.id][:count]
                best[overview.id] = {
                    id:         overview.id,
                    name:       overview.name,
                    link:       overview.link,
                    count:      ticket_count,
                    best_agent: agent.login
                }
            end
        rescue => e
            # Stille Fehler – Progressbar soll nicht zerstört werden
        end
    end
end

# Zeilenumbruch nach Progressbar
puts "\n\n"
puts "=" * 60

top3 = best.values.sort_by { |r| r[:count] }.reverse.first(3)

if top3.empty?
    puts "Keine Ergebnisse gefunden."
else
    top3.each_with_index do |entry, index|
        medal = ["🥇", "🥈", "🥉"][index]
        puts "#{medal}  Platz #{index + 1}: #{entry[:name]}"
        puts "    ID:          #{entry[:id]}"
        puts "    Link:        /#{entry[:link]}"
        puts "    Max Tickets: #{entry[:count]}"
        puts "    Bester Agent: #{entry[:best_agent]}"
        puts "-" * 60
    end
end

puts
puts "📊 Analysierte Übersichten: #{overviews.size}"
puts "👥 Analysierte Agenten:     #{agents.size}"
puts "🔢 Gesamt-Iterationen:      #{total_steps}"
