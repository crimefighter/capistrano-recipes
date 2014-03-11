This is a collection of Capistrano recipes I use to deploy Rails apps. It allows to:
* Configure new rails server with a single command (cap setup:install_packages && cap setup:server)
* Upload configs and git keys
* Configure and launch SOLR (TODO: Sphinx)
* Add NewRelic server monitoring
* Manage named Delayed Job queues, assign multiple workers to each queue (cap delayed_job:start_multiple)
* View application logs in real time and use console (cap rails:console and cap logs:application, works similar to Heroku)