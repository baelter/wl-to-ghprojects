#!/usr/bin/env ruby
require 'wunderlist'
require 'excon'
require 'optparse'

Wunderlist::List.class_eval do
  def initialize(attrs = {})
    puts "attrs #{attrs}" if attrs.is_a?(Array)
    @api = attrs['api']
    @id = attrs['id']
    @title = attrs['title']
    @created_at = attrs['created_at']
    @revision = attrs['revision']
  end
end

options = {
  client_id: ENV['WL_CLIENT_ID'],
  client_secret: ENV['WL_CLIENT_SECRET'],
  token: ENV['GITHUB_TOKEN'],
  org: ENV['GITHUB_ORG'],
  user: ENV['GITHUB_USER'],
  repo: ENV['GITHUB_REPO']
}
optparse = OptionParser.new do |opts|
  opts.banner = "Usage: #{File.basename $PROGRAM_NAME} [options] list"

  opts.on("-c", "--client-id id", "Wunderlist CLIENT_ID") do |id|
    options[:client_id] = id
  end
  opts.on("-s", "--client_secret secret", "Wunderlist CLIENT_SECRET") do |secret|
    options[:client_secret] = secret
  end
  opts.on("-t", "--token token", "Github OAUTH_TOKEN") do |token|
    options[:github_token] = token
  end
  opts.on("-o", "--org org", "Github organisation") do |org|
    options[:org] = org
  end
  opts.on("-u", "--user user", "Github user") do |user|
    options[:user] = user
  end
  opts.on("-r", "--repo repo", "Github repo") do |repo|
    options[:repo] = repo
  end
  opts.on_tail("-h", "--help", "Show this message") do
    puts opts
    exit 1
  end
end

optparse.parse!

options[:list] = ARGV.pop

begin
  raise "Set list name" unless options[:list]
  raise "Set Wunderlist client id" unless options[:client_id]
  raise "Set Wunderlist client secret" unless options[:client_secret]
  raise "Set Github token" unless options[:token]
  raise "Set user & repo or organization" unless options[:org] || (options[:user] && options[:repo])
rescue => e
  puts e.message
  puts optparse
  exit 1
end

wl = Wunderlist::API.new(access_token: options[:client_secret], client_id: options[:client_id])

class GitHub
  def initialize(options)
    @base_path = if org = options[:org]
                   "/orgs/#{org}/projects"
                 else
                   "/repos/#{options[:user]}/#{options[:repo]}/projects"
                 end
    @api = Excon.new "https://api.github.com#{@base_path}",
                     headers: {
                       Authorization: "token #{options[:token]}",
                       'User-Agent': "wl-to-ghprojects",
                       'Content-Type': "application/json",
                       Accept: 'application/vnd.github.inertia-preview+json'
                     },
                     debug_request: true, debug_response: true, expects: [200, 201, 204]
  end
  attr_reader :base_path

  def call(method, opts = {})
    response = @api.send(method, opts)
    next_link = response.headers['Link']&.split(',')&.find { |l| l =~ /rel="next"/ }
    resp = JSON.parse(response.body, symbolize_names: true) unless response.body.to_s.empty?
    if next_link
      puts "getting #{next_link}"
      path = next_link[/<(.*?)>;/, 1].split('api.github.com').last
      resp += call(:get, path: path)
    end
    resp
  end
end

gh = GitHub.new(options)

projects = gh.call(:get)
puts "Syncing Wunderlist list: #{options[:list]}"
wl_list = wl.list(options[:list])
raise "Could not find list: #{options[:list]}" unless wl_list
until project ||= projects.find { |p| p[:name] == wl_list.title }
  puts "Creating Github Project: #{options[:list]}"
  project = gh.call(:post, body: { name: wl_list.title }.to_json)
  projects << project
end
col = gh.call(:get, path: "projects/#{project[:id]}/columns").first
cards = gh.call(:get, path: "projects/columns/#{col[:id]}/cards")
puts "Clear #{cards.size} old cards"
cards.each do |c|
  gh.call(:delete, path: "projects/columns/cards/#{c[:id]}")
end
wl_list.tasks.each do |task|
  puts "Creating card: #{task.title}"
  note = task.title
  begin
    note += "\n" + task.note.content.to_s
  rescue JSON::ParserError; end
  note += "\n" + task.task_comments.map(&:text).join("\n")
  note = note[0..249]
  gh.call(:post, path: "projects/columns/#{col[:id]}/cards",
                 body: { note: note }.to_json)
end
