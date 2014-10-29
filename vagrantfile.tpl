# -*- mode: ruby -*-
# # vi: set ft=ruby :

Vagrant.require_version ">= 1.6.3"

#stolen from github.com/fnichol/dvm
def shq(s)  # sh(1)-style quoting
  sprintf("'%s'", s.gsub(/'/, "'\\\\''"))
end

ip      = ENV.fetch("DOCKER_IP", "192.168.42.43")
memory  = ENV.fetch("DOCKER_MEMORY", "512")
cpus    = ENV.fetch("DOCKER_CPUS", "1")
cidr    = ENV.fetch("DOCKER0_CIDR", "")
args    = ENV.fetch("DOCKER_ARGS", "")

b2d_version = "1.3.0"
release_url = "https://github.com/fnichol/boot2docker-vagrant-box/releases/download/v#{b2d_version}"

docker0_bridge_setup = ""
bridge_utils_url     = "ftp://ftp.nl.netbsd.org/vol/2/metalab/distributions/tinycorelinux/4.x/x86/tcz/bridge-utils.tcz"
unless cidr.empty?
  args += " --bip=#{cidr}"

  as_docker_usr     = 'su - docker -c'
  dl_dir            = '/home/docker'
  filename          = 'bridge-utils.tcz'
  dl_br_utils       = "wget -P #{dl_dir} -O #{filename} #{shq(bridge_utils_url)}"
  install_br_utils  = "tce-load -i #{dl_dir}/#{filename}"
  brctl             = '/usr/local/sbin/brctl'
  ifcfg             = '/sbin/ifconfig'
  take_docker0_down = "#{ifcfg} docker0 down"
  delete_docker0    = "#{brctl} delbr docker0"

  docker0_bridge_setup = <<-BRIDGE_SETUP
    sudo $INITD stop
    echo #{shq("#{as_docker_usr} #{shq(dl_br_utils)}")}
    #{as_docker_usr} #{shq(dl_br_utils)}
    echo #{shq("#{as_docker_usr} #{shq(install_br_utils)}")}
    #{as_docker_usr} #{shq(install_br_utils)}
    sudo #{take_docker0_down}
    sudo #{delete_docker0}
  BRIDGE_SETUP
end

def tinycore_supported?
  Gem::Version.new(Vagrant::VERSION) >= Gem::Version.new("1.5.0")
end

module VagrantPlugins
  module GuestTinyCore
    module Cap ; end

    class Plugin < Vagrant.plugin("2")
      name "TinyCore Linux guest."
      description "TinyCore Linux guest support."

      if !tinycore_supported?
        guest("tinycore", "linux") do
          class ::VagrantPlugins::GuestTinyCore::Guest < Vagrant.plugin("2", :guest)
            def detect?(machine)
              machine.communicate.test("cat /etc/issue | grep 'Core Linux'")
            end
          end
          Guest
        end
      end

      if !tinycore_supported?
        guest_capability("tinycore", "halt") do
          class ::VagrantPlugins::GuestTinyCore::Cap::Halt
            def self.halt(machine)
              machine.communicate.sudo("poweroff")
            rescue IOError
              # Do nothing, because it probably means the machine shut down
              # and SSH connection was lost.
            end
          end
          Cap::Halt
        end
      end

      guest_capability("tinycore", "configure_networks") do
        class ::VagrantPlugins::GuestTinyCore::Cap::ConfigureNetworks
          def self.configure_networks(machine, networks)
            require 'ipaddr'
            machine.communicate.tap do |comm|
              networks.each do |n|
                ifc = "/sbin/ifconfig eth#{n[:interface]}"
                pid = "/var/run/udhcpc.eth#{n[:interface]}.pid"
                broadcast = (IPAddr.new(n[:ip]) | (~ IPAddr.new(n[:netmask]))).to_s
                comm.sudo("#{ifc} down")
                comm.sudo("if [ -f #{pid} ]; then kill `cat #{pid}` && rm -f #{pid}; fi")
                comm.sudo("printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\n' > /etc/resolv.conf")
                comm.sudo("#{ifc} #{n[:ip]} netmask #{n[:netmask]} broadcast #{broadcast}")
                comm.sudo("#{ifc} up")
              end
            end
          end
        end
        Cap::ConfigureNetworks
      end
    end
  end
end
Vagrant.configure("2") do |config|
  config.ssh.shell = "sh"
  config.ssh.username = "docker"

  # Disable synced folder by default
  config.vm.synced_folder ".", "/vagrant", disabled: true

  # Attach the b2d ISO so that it can boot
  config.vm.provider :virtualbox do |v|
    v.check_guest_additions = false
    v.customize "pre-boot", [
      "storageattach", :id,
      "--storagectl", "IDE Controller",
      "--port", "0",
      "--device", "1",
      "--type", "dvddrive",
      "--medium", File.expand_path("../boot2docker.iso", __FILE__),
    ]
    v.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
    v.customize ["modifyvm", :id, "--natdnsproxy1", "on"]
  end
  ["vmware_fusion", "vmware_workstation"].each do |vmware|
    config.vm.provider vmware do |v|
      v.vmx["bios.bootOrder"]    = "CDROM,hdd"
      v.vmx["ide1:0.present"]    = "TRUE"
      v.vmx["ide1:0.fileName"]   = File.expand_path("../boot2docker.iso", __FILE__)
      v.vmx["ide1:0.deviceType"] = "cdrom-image"
    end
  end
  config.vm.provider :parallels do |p|
    p.check_guest_tools = false
    p.functional_psf = false
    p.customize "pre-boot", [
      "set", :id,
      "--device-set", "cdrom0",
      "--image", File.expand_path("../boot2docker.iso", __FILE__),
      "--enable", "--connect"
    ]
    p.customize "pre-boot", [
      "set", :id,
      "--device-bootorder", "cdrom0 hdd0"
    ]
  end

  args = "export EXTRA_ARGS=#{shq args.strip}" unless args.empty?

  config.vm.provision :shell, :inline => <<-PREPARE
    INITD=/usr/local/etc/init.d/docker
    PROFILE=/var/lib/boot2docker/profile
    #{docker0_bridge_setup}
    rm -f $PROFILE && touch $PROFILE

    if [ -n #{shq(args)} ]; then
      echo '---> Configuring docker with args "'#{shq(args)}'"'
      echo #{shq(args)} >> $PROFILE
    fi

    if [ -s "$PROFILE" ]; then
      echo '---> Restarting docker daemon'
      sudo $INITD restart
    fi
    echo "boot2docker: $(cat /etc/version)"
  PREPARE

end
