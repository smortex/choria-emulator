require 'net/http'
require 'base64'

module MCollective
  module Agent
    class Emulator<RPC::Agent
      action "download" do
        reply[:success] = false

        FileUtils.mkdir_p("/tmp/choria-emulator")

        if request[:http]
          target = File.join("/tmp/choria-emulator", request[:target])

          begin
            download_http(request[:http], target)
          rescue
            reply.fail!("Failed to download %s: %s: %s" % [request[:http], $!.class, $!.to_s])
          end

          stat = File::Stat.new(target)
          reply[:size] = stat.size
          reply[:success] = true
          reply[:md5] = md5(target)
        else
          reply.fail("No valid download location given")
        end
      end

      action "start" do
        unless File.exist?("/tmp/choria-emulator/choria-emulator")
          reply.fail!("Cannot start /tmp/choria-emulator/choria-emulator does not exist")
        end

        FileUtils.chmod(0755, "/tmp/choria-emulator/choria-emulator")

        if up?(request[:monitor])
          reply.fail!("Cannot start, emulator is already running")
        end

        args = []

        args << "--instances %d" % request[:instances]
        args << "--http-port %d" % request[:monitor]
        args << "--config /dev/null"
        args << "--agents %d" % request[:agents] if request[:agents]
        args << "--collectives %d" % request[:collectives] if request[:collectives]
        args << "--tls" if request[:tls]

        if request[:credentials]
          creds = Base64.decode64(request[:credentials])
          File.open("/tmp/choria-emulator/credentials", "w") {|f| f.print(creds)}
          args << "--credentials /tmp/choria-emulator/credentials"
        end

        if request[:name]
          args << "--name %s" % request[:name]
        else
          args << "--name %s" % config.identity
        end

        if request[:servers]
          request[:servers].split(",").each do |server|
            args << "--server %s" % server.gsub(" ", "")
          end
        end

        out = []
        err = []
        Log.info("Running: %s" % args.join(" "))

        run('(/tmp/choria-emulator/choria-emulator %s 2>&1 >> /tmp/choria-emulator/log &) &' % args.join(" "), :stdout => out, :stderr => err)

        sleep 1

        reply[:status] = up?(request[:monitor])
      end

      action "stop" do
        reply[:status] = false

        if up?(request[:port])
          pid = emulator_pid(request[:port])

          reply.fail!("Could not determine PID for running emulator") unless pid

          Process.kill("HUP", pid)
          sleep 1
          reply[:status] = down?(request[:port])
        end
      end

      action "emulator_status" do
        if File.exist?("/tmp/choria-emulator/choria-emulator")
          reply[:emulator] = md5("/tmp/choria-emulator/choria-emulator")
        end

        if down?(request[:port])
          reply[:running] = false
          break
        end

        status = emulator_status(request[:port])

        reply[:name] = status["name"]
        reply[:running] = true
        reply[:pid] = status["config"]["pid"]
        reply[:tls] = status["config"]["TLS"] == 1
        reply[:memory] = status["memstats"]["Sys"]
      end

      action "start_nats" do
        unless File.exist?("/tmp/choria-emulator/nats-server")
          reply.fail!("/tmp/choria-emulator/nats-server does not exist")
        end

        reply.fail!("NATS is already running") if nats_running?

        FileUtils.chmod(0755, "/tmp/choria-emulator/nats-server")

        run('(/tmp/choria-emulator/nats-server -T --log /tmp/choria-emulator/nats-server.log --pid /tmp/choria-emulator/nats-server.pid --port %s --http_port %s 2>&1 >> /tmp/choria-emulator/nats-server.log &) &' % [request[:port], request[:monitor_port]], :stdout => (out=[]), :stderr => (err=[]))

        sleep 1

        reply[:running] = nats_running?
      end

      action "stop_nats" do
        if nats_running?
          kill_pid("nats-server.pid")
          sleep 1
        end

        reply[:stopped] = !nats_running?
      end

      action "start_federation" do
        unless File.exist?("/tmp/choria-emulator/choria")
          reply.fail!("/tmp/choria-emulator/choria does not exist")
        end

        reply.fail("Federation Broker is already running") if federation_running?

        File.open("/tmp/choria-emulator/federation.cfg", "w") do |cfg|
          cfg.puts("identity = %s" % config.identity)
          cfg.puts("logfile = /tmp/choria-emulator/choria.log")
          cfg.puts("loglevel = info")
          cfg.puts("plugin.choria.broker_federation = true")
          cfg.puts("plugin.choria.federation_middleware_hosts = %s" % request[:federation_servers])
          cfg.puts("plugin.choria.middleware_hosts = %s" % request[:collective_servers])
          cfg.puts("plugin.choria.broker_federation_cluster = %s" % (request[:name] || config.identity))
        end

        FileUtils.chmod(0755, "/tmp/choria-emulator/choria")

        tls = request[:tls] ? "" : "--disable-tls"

        Log.debug(request[:tls])
        run('(/tmp/choria-emulator/choria broker run --pid /tmp/choria-emulator/federation.pid --config /tmp/choria-emulator/federation.cfg %s 2>&1 >> /tmp/choria-emulator/federation.log & ) &' % tls, :stdout => (out=[]), :stderr => (err=[]))
        Log.debug(out.inspect)
        Log.debug(err.inspect)

        sleep 1

        reply[:running] = federation_running?
      end

      action "stop_federation" do
        if federation_running?
          kill_pid("federation.pid")
          sleep 1
        end

        reply[:stopped] = !federation_running?
      end

      def federation_running?
        pid_running?("federation.pid")
      end

      def nats_running?
        pid_running?("nats-server.pid")
      end

      def kill_pid(pidfile)
        file = File.join("/tmp/choria-emulator", pidfile)

        raise("%s does not exist" % file) unless File.exist?(file)

        Process.kill("HUP", Integer(File.read(file).chomp))

        sleep 0.2

        if pid_running?(pidfile)
          sleep 1
          Process.kill("KILL", Integer(File.read(file).chomp))
        end
      end

      def pid_running?(pidfile)
        file = File.join("/tmp/choria-emulator", pidfile)

        return false unless File.exist?(file)

        File.exist?("/proc/%d" % File.read(file).chomp)
      end

      def md5(file)
        run("/bin/md5sum %s" % file, :stdout => stdout = [], :sterr => [])
        stdout.first.split(/\s/).first
      end

      def up?(port)
        Log.debug(emulator_status(port).inspect)
        emulator_status(port)["status"] == "up"
      rescue
        Log.warn("%s: %s" % [$!.class, $!.to_s])
        false
      end

      def down?(port)
        !up?(port)
      end

      def emulator_pid(port)
        emulator_status(port)["config"]["pid"]
      end

      def emulator_status(port=8080)
        uri = URI.parse("http://localhost:%d/debug/vars" % port)
        response = Net::HTTP.get_response(uri)

        out = {
          "status" => "up",
          "code" => response.code
        }

        if response.code == "200"
          Log.debug(response.body)
          out.merge!(JSON.parse(response.body))
        end

        out
      end

      def download_http(url, target)
        uri = URI.parse(url)
        out = File.open(target, "wb")

        begin
          Net::HTTP.get_response(uri) do |resp|
            resp.read_body do |segment|
              out.write(segment)
            end
          end
        ensure
          out.close
        end
      end
    end
  end
end
