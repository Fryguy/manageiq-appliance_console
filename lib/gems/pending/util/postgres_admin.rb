require 'awesome_spawn'
require 'pathname'
require 'linux_admin'

RAILS_ROOT ||= Pathname.new(__dir__).join("../../../")

class PostgresAdmin
  def self.data_directory
    Pathname.new(ENV.fetch("APPLIANCE_PG_DATA"))
  end

  def self.mount_point
    Pathname.new(ENV.fetch("APPLIANCE_PG_MOUNT_POINT"))
  end

  def self.template_directory
    Pathname.new(ENV.fetch("APPLIANCE_TEMPLATE_DIRECTORY"))
  end

  def self.service_name
    ENV.fetch("APPLIANCE_PG_SERVICE")
  end

  def self.package_name
    ENV.fetch('APPLIANCE_PG_PACKAGE_NAME')
  end

  # Unprivileged user to run postgresql
  def self.user
    "postgres".freeze
  end

  def self.certificate_location
    RAILS_ROOT.join("certs")
  end

  def self.logical_volume_name
    "lv_pg".freeze
  end

  def self.volume_group_name
    "vg_data".freeze
  end

  def self.database_disk_filesystem
    "xfs".freeze
  end

  def self.initialized?
    !Dir[data_directory.join("*")].empty?
  end

  def self.service_running?
    LinuxAdmin::Service.new(service_name).running?
  end

  def self.local_server_in_recovery?
    data_directory.join("recovery.conf").exist?
  end

  def self.local_server_status
    if service_running?
      "running (#{local_server_in_recovery? ? "standby" : "primary"})"
    elsif initialized?
      "initialized and stopped"
    else
      "not initialized"
    end
  end

  def self.logical_volume_path
    Pathname.new("/dev").join(volume_group_name, logical_volume_name)
  end

  def self.database_size(opts)
    result = runcmd("psql", opts, :command => "SELECT pg_database_size('#{opts[:dbname]}');")
    result.match(/^\s+([0-9]+)\n/)[1].to_i
  end

  def self.prep_data_directory
    # initdb will fail if the database directory is not empty or not owned by the PostgresAdmin.user
    FileUtils.mkdir(PostgresAdmin.data_directory) unless Dir.exist?(PostgresAdmin.data_directory)
    FileUtils.chown_R(PostgresAdmin.user, PostgresAdmin.user, PostgresAdmin.data_directory)
    FileUtils.rm_rf(PostgresAdmin.data_directory.children.map(&:to_s))
  end

  def self.backup(opts)
    backup_pg_compress(opts)
  end

  def self.restore(opts)
    restore_pg_compress(opts)
  end


  def self.unload_pglogical_extension(opts)
    runcmd("psql", opts, :command => <<-SQL)
      SELECT
        drop_subscription
      FROM
        pglogical.subscription subs,
        LATERAL pglogical.drop_subscription(subs.sub_name)
    SQL

    runcmd("psql", opts, :command => <<-SQL)
      DROP EXTENSION pglogical CASCADE
    SQL

    # Wait for pglogical manager connection to quiesce. Bail after 5 minutes
    60.times do
      output = runcmd("psql", opts, :command => <<-SQL)
        SELECT application_name
        FROM pg_stat_activity
        WHERE application_name LIKE 'pglogical manager%'
      SQL
      match = /^\((?<count>\d+) row/.match(output)
      count = match ? match[:count].to_i : 0
      break if count.zero?

      $log.info("MIQ(#{name}.#{__method__}) Waiting on #{count} pglogical connections to close...")
      sleep 5
    end
  rescue AwesomeSpawn::CommandResultError
    $log.info("MIQ(#{name}.#{__method__}) Ignoring failure to remove pglogical before restore ...")
  end

  def self.backup_pg_compress(opts)
    opts = opts.dup

    # discard dbname as pg_basebackup does not connect to a specific database
    opts.delete(:dbname)

    path = Pathname.new(opts.delete(:local_file))

    runcmd("pg_basebackup", opts, :z => nil, :format => "t", :xlog_method => "fetch", :pgdata => path.dirname)
    FileUtils.mv(path.dirname.join("base.tar.gz"), path)
    path.to_s
  end

  def self.recreate_db(opts)
    dbname = opts[:dbname]
    opts = opts.merge(:dbname => 'postgres')
    runcmd("psql", opts, :command => "DROP DATABASE IF EXISTS #{dbname}")
    runcmd("psql", opts,
           :command => "CREATE DATABASE #{dbname} WITH OWNER = #{opts[:username] || 'root'} ENCODING = 'UTF8'")
  end

  def self.restore_pg_compress(opts)
    unload_pglogical_extension(opts)
    recreate_db(opts)

    runcmd("pg_restore", opts, :verbose => nil, :exit_on_error => nil, nil => opts[:local_file])
    opts[:local_file]
  end

  GC_DEFAULTS = {
    :analyze  => false,
    :full     => false,
    :verbose  => false,
    :table    => nil,
    :dbname   => nil,
    :username => nil,
    :reindex  => false
  }

  GC_AGGRESSIVE_DEFAULTS = {
    :analyze  => true,
    :full     => true,
    :verbose  => false,
    :table    => nil,
    :dbname   => nil,
    :username => nil,
    :reindex  => true
  }

  def self.gc(options = {})
    options = (options[:aggressive] ? GC_AGGRESSIVE_DEFAULTS : GC_DEFAULTS).merge(options)

    result = vacuum(options)
    $log.info("MIQ(#{name}.#{__method__}) Output... #{result}") if result.to_s.length > 0

    if options[:reindex]
      result = reindex(options)
      $log.info("MIQ(#{name}.#{__method__}) Output... #{result}") if result.to_s.length > 0
    end
  end

  def self.vacuum(opts)
    # TODO: Add a real exception here
    raise "Vacuum requires database" unless opts[:dbname]

    args = {}
    args[:analyze] = nil if opts[:analyze]
    args[:full]    = nil if opts[:full]
    args[:verbose] = nil if opts[:verbose]
    args[:table]   = opts[:table] if opts[:table]
    runcmd("vacuumdb", opts, args)
  end

  def self.reindex(opts)
    args = {}
    args[:table] = opts[:table] if opts[:table]
    runcmd("reindexdb", opts, args)
  end

  def self.runcmd(cmd_str, opts, args)
    default_args            = {:no_password => nil}
    default_args[:dbname]   = opts[:dbname]   if opts[:dbname]
    default_args[:username] = opts[:username] if opts[:username]
    default_args[:host]     = opts[:hostname] if opts[:hostname]
    args = default_args.merge(args)

    runcmd_with_logging(cmd_str, opts, args)
  end

  def self.runcmd_with_logging(cmd_str, opts, params = {})
    $log.info("MIQ(#{name}.#{__method__}) Running command... #{AwesomeSpawn.build_command_line(cmd_str, params)}")
    AwesomeSpawn.run!(cmd_str, :params => params, :env => {
                        "PGUSER"     => opts[:username],
                        "PGPASSWORD" => opts[:password]}).output
  end
end
