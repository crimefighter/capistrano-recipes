require 'capistrano/ext/multistage'
require 'bundler/capistrano'
require 'capistrano-helpers/bundler'
require 'rvm/capistrano'
require "delayed/recipes"
require 'whenever/capistrano'

# RVM
set :using_rvm,             true
set :rvm_ruby_string,       "ruby-2.0.0-p353@YOUR_GEMSET"
set :rvm_type,              :system
set :rvm_install_with_sudo, true

set :passenger_version,     '4.0.3'
set :passenger_ruby, 'ruby-2.0.0-p353'

set :application,      'APP_NAME'

set :scm,              :git
set :repository,       'GIT_URL'
set :scm_passphrase,   ''

set :stages,           ['staging', 'production']
set :default_stage,    'staging'
set :deploy_via,       :remote_cache

set :bundle_flags, ""

set :delayed_job_command, "bin/delayed_job"
set :delayed_job_server_role, :delayed_job

set :delayed_job_queues, {queue_name: 1} #workers count per queue

ssh_options[:forward_agent] = true
default_run_options[:pty] = true
set :use_sudo, false

set :private_key,       "/path/to/ssh/key" # this key is used for recipes like rails:console
set :git_private_key,   "/path/to/ssh/git/key" # private key to access git repository. I recommend using repository deploy key rather than user specific key

set :whenever_command, "bundle exec whenever"

set :newrelic_license_key, 'NEWRELIC_KEY'

set :keep_releases, 2

set :packages_to_install, ""

namespace :setup do

  task :server do
    rvm.install_rvm
    rvm.install_ruby
    upload_git_key
    make_apps_dir
    deploy.setup
    install_bundler
    install_nginx
    upload_config
  end

  task :logrotate do # update logrotate config with one from config/deploy
    sudo_put File.read("config/deploy/#{application}"), "/etc/logrotate.d/#{application}"
  end

  task :make_apps_dir do
    run "if [ ! -d /apps ]; then sudo mkdir /apps && sudo chown #{user}:#{user} /apps; fi"
  end

  task :install_packages do
    hostname = find_servers_for_task(current_task).first
    exec "ssh -l #{user} #{hostname} -i #{private_key} -t 'sudo apt-get update && sudo apt-get install nginx git-core libcurl4-openssl-dev build-essential libreadline6-dev libyaml-dev autoconf libgdbm-dev libncurses5-dev automake bison libffi-dev #{packages_to_install}'"
  end

  task :upload_git_key do
    hostname = find_servers_for_task(current_task).first
    run_locally "scp #{git_private_key} #{user}@#{hostname}:#{git_private_/key}"
    run "ssh-agent -s && ssh-add #{git_private_key}"
  end

  task :upload_config do
    run "if [ ! -d #{shared_path}/config ]; then mkdir #{shared_path}/config; fi"
    {}.merge(config_files).each do |remote_filename, local_filename|
      top.upload( local_filename, "#{shared_path}/config/#{remote_filename}", :via => :scp)
    end
  end

  task :install_bundler do
    run "sudo rvm_path=/usr/local/rvm /usr/local/rvm/bin/rvm-shell '#{rvm_ruby_string}' -c 'gem install bundler'"
  end
 
  task :install_nginx do
    run "rvm_path=/usr/local/rvm /usr/local/rvm/bin/rvm-shell '#{rvm_ruby_string}' -c 'gem install passenger -v #{passenger_version}'"
    run "sudo rvm_path=/usr/local/rvm /usr/local/rvm/bin/rvm-shell '#{rvm_ruby_string}' -c 'passenger-install-nginx-module --auto --auto-download --prefix=/opt/nginx'"
    sudo_put File.read('config/deploy/nginx'), "/etc/init.d/nginx"
    run "sudo chmod +x /etc/init.d/nginx"
    update_nginx_config
  end

  task :update_nginx_config do
    config = File.read('config/deploy/nginx.conf') % {
      :passenger_version => passenger_version, 
      :passenger_ruby => passenger_ruby, 
      :ruby_string => rvm_ruby_string,
      :root => deploy_to, :rails_env => rails_env, 
      :nginx_server_name => nginx_server_name
    }
    sudo_put config, "/opt/nginx/conf/nginx.conf" 
  end

  task :s3 do
    hostname = find_servers_for_task(current_task).first
    exec "ssh -l #{user} #{hostname} -i #{private_key} -t 'sudo apt-get install s3cmd && s3cmd --configure'"
  end

  task :server_monitoring do
    run "sudo su - root -c 'echo deb http://apt.newrelic.com/debian/ newrelic non-free >> /etc/apt/sources.list.d/newrelic.list'"
    run "sudo su - root -c 'wget -O- https://download.newrelic.com/548C16BF.gpg | apt-key add -'"
    run "sudo apt-get update"
    run "sudo apt-get install newrelic-sysmond"
    run "sudo nrsysmond-config --set license_key=#{newrelic_license_key}"
    run "sudo /etc/init.d/newrelic-sysmond start"
  end
end

namespace :deploy do

  desc "Start application"
  task :start, :roles => :app, :except => { :no_release => true } do
    #run "cd #{current_path} && bundle exec unicorn_rails -E #{rails_env} -c config/unicorn.rb -D"
    run 'sudo /etc/init.d/nginx start'
  end

  desc "Stop application"
  task :stop, :roles => :app, :except => { :no_release => true }  do
    #run "if [ -f #{unicorn_pid} ] && [ -e /proc/$(cat #{unicorn_pid}) ]; then kill -QUIT `cat #{unicorn_pid}`; fi"
    run 'sudo /etc/init.d/nginx stop'
  end

  desc "Restart application"
  task :restart, :roles => :app, :except => { :no_release => true } do
    stop
    start
  end

  desc "Create additional symlinks"
  task :symlink_configs, :role => :app do
    run "ln -nfs #{shared_path}/config/database.yml #{latest_release}/config/database.yml"
    #run "ln -nfs #{shared_path}/config/unicorn.rb #{latest_release}/config/unicorn.rb"
  end
end

namespace :solr do
  task :start do
    run("cd #{current_path} && RAILS_ENV=#{rails_env} bundle exec rake sunspot:solr:start")
  end

  task :reindex do
    run("cd #{current_path} && RAILS_ENV=#{rails_env} bundle exec rake sunspot:solr:reindex")
  end

  task :stop do
    run("if [ -d \"#{current_path}\" ]; then cd #{current_path} && RAILS_ENV=#{rails_env} bundle exec rake sunspot:solr:stop; fi")
  end
end

desc "View logs in real time"
namespace :logs do
  desc "Application log"
  task :application do
    watch_log("cd #{current_path} && tail -f log/#{rails_env}.log")
  end
end

namespace :rails do
  desc "Remote console"
  task :console, :roles => :app do
    hostname = find_servers_for_task(current_task).first
    exec "ssh -l #{user} #{hostname} -i #{private_key} -t \"source ~/.profile && cd #{current_path} && rvm_path=/usr/local/rvm /usr/local/rvm/bin/rvm-shell '#{rvm_ruby_string}' -c 'bundle exec rails c #{rails_env}'\""
  end

  task :runner, :roles => :app do
    hostname = find_servers_for_task(current_task).first
    exec "ssh -l #{user} #{hostname} -i #{private_key} -t \"source ~/.profile && cd #{current_path} && rvm_path=/usr/local/rvm /usr/local/rvm/bin/rvm-shell '#{rvm_ruby_string}' -c 'bundle exec rails runner '#{command}' RAILS_ENV=#{rails_env}'\""
  end
end

namespace :db do
  task :backup, roles: :db do
    run("cd #{current_path} && RAILS_ENV=#{rails_env} bundle exec rake db:backup")
  end
end

namespace :maintenance do
  task :on do
    put File.read('config/deploy/maintenance.html'), "#{current_path}/public/maintenance.html"
  end

  task :off do
    run("cd #{current_path} && rm public/maintenance.html")
  end
end

namespace :delayed_job do
  task :start_multiple, roles: -> { fetch(:delayed_job_server_role, :app) } do
    counter = 1
    fetch(:delayed_job_queues, {}).each do |queue, count|
      count.to_i.times do
        run "cd #{current_path};#{rails_env} #{delayed_job_command} --queue=#{queue} -i #{counter} start"
        counter = counter.next
      end
    end
  end
end

before "deploy:assets:precompile", "deploy:symlink_configs"
after "deploy:update_code", "deploy:migrate"

after "deploy:restart", "deploy:cleanup"

after 'deploy:cleanup', 'whenever:update_crontab'
after 'deploy:rollback', 'whenever:update_crontab'

after "deploy:stop",    "delayed_job:stop"
after "deploy:start",   "delayed_job:start_multiple"

# View logs helper
def watch_log(command)
  raise "Command is nil" unless command
  run command do |channel, stream, data|
    print data
    trap("INT") { puts 'Interupted'; exit 0; }
    break if stream == :err
  end
end

def sudo_put(data, target)
  tmp = "#{shared_path}/~tmp-#{rand(9999999)}"
  put data, tmp
  on_rollback { run "rm #{tmp}" }
  sudo "cp -f #{tmp} #{target} && rm #{tmp}"
end
