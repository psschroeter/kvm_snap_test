require 'rubygems'
require 'logger'

class SnapTestRunner

  attr_reader :api, :log

  def check_environment
    %w(MASTER_IP MASTER_ID SLAVE_IP SLAVE_ID CLOUD_KEY).each do |key|
      raise "VARIABLE NOT SET: #{key}" unless ENV.key?(key)
    end
  end

  def initialize(api, logger = Logger.new(STDOUT))
    check_environment
    @api = api
    @log = logger
  end

  # Utility for sending commands to VM
  # Requires VMs to have publish SSH key installed.
  def remote_cmd(ip_addr, command)
    ret = `ssh -i #{ENV['CLOUD_KEY']} root@#{ip_addr} '#{command}'`
    puts ret
    ret
  end

  def sleep_now(seconds)
    log.info("Sleeping #{seconds} seconds...")
    sleep seconds
  end

  def run(cleanup = true)
    start_time = Time.now
    log.info("Starting test at #{start_time}")

    # Setup
    #
    remote_cmd(ENV['MASTER_IP'], "mkdir /mnt/master") # for mounting source volume
    remote_cmd(ENV['SLAVE_IP'],"mkdir /mnt/slave")  # for mounting snapshots volumes 
    # 
    # Create and attach volume to "master" VM
    # 
    master_volume_id = api.volume_create("kvm_test_master") 
    # gather on to the list of current devices (KVM Workaround - part 1)  
    partitions = remote_cmd(ENV['MASTER_IP'], "cat /proc/partitions")
    devices_before_attach = api.get_current_devices(partitions)
    device = api.volume_attach(ENV['MASTER_ID'], master_volume_id)
    log.info "KVM WORKAROUND PART1: ignoring device from API #{device}"
    # don't believe device returned by API (KVM Workaround - part 2)
    partitions = remote_cmd(ENV['MASTER_IP'], "cat /proc/partitions")
    current_devices = api.get_current_devices(partitions)
    device = (Set.new(current_devices) - Set.new(devices_before_attach)).first
    log.info "KVM WORKAROUND PART2: using device #{device}"

    #
    # Create xfs filesystem, mount and create testfile
    #
    remote_cmd(ENV['MASTER_IP'], "mkfs.xfs #{device}")
    remote_cmd(ENV['MASTER_IP'], "mount #{device} /mnt/master")
    remote_cmd(ENV['MASTER_IP'], "sync")

    # Test loop
    #
    count = 0
    passing = true
    while (passing)
      count += 1
      log.info "Pass #{count}"

      # Create testfile for compare
      log.info "Generating new testfile..."
      remote_cmd(ENV['MASTER_IP'], "dd if=/dev/urandom of=/mnt/master/testfile bs=1024 count=524288")
      log.info "Calculate fingerprint of testfile..."
      r = remote_cmd(ENV['MASTER_IP'], "md5sum /mnt/master/testfile")
      md5_orig = r.split(" ").first


      #
      # Sync filesystem and take snapshot of master volume
      #
      log.info " Take snapshot, create a volume from it, and attach to slave..."
      remote_cmd(ENV['MASTER_IP'], "sync")
      snap_id = api.snapshot_create(master_volume_id)    

      debugger if ENV['MIDSTOP']

      #
      # Create volume from snapshot and attach to "slave" VM
      #
      slave_id = api.volume_create_from_snap("kvm_test_master", "kvm_test_slave", snap_id)
      log.info "KVM WORKAROUND PART1: ignoring device from API #{device}"
      device = api.volume_attach(ENV['SLAVE_ID'], slave_id)
      # don't believe device returned by API (KVM Workaround - part 2)
      partitions = remote_cmd(ENV['SLAVE_IP'], "cat /proc/partitions")
      current_devices = api.get_current_devices(partitions)
      device = (Set.new(current_devices) - Set.new(devices_before_attach)).first
      log.info "KVM WORKAROUND PART2: using device #{device}"

      #
      # Verify that the testfile fingerprints match (fail if they dont)
      #
      log.info "  Verify the fingerprint of testfile..."
      remote_cmd(ENV['SLAVE_IP'],"mount #{device} /mnt/slave")
      r = remote_cmd(ENV['SLAVE_IP'],"md5sum /mnt/slave/testfile")
      md5_snap = r.split(" ").first
      if md5_orig == md5_snap
        log.info "  PASS: snapshot files match! Orig:#{md5_orig} From Snapshot:#{md5_snap}"
      else
        log.error "  FAIL: signatures don't match. Orig:#{md5_orig} From Snapshot:#{md5_snap}" 
        passing = false
      end

      #
      # Cleanup for next iteration (or unless we failed and cleanup == false)
      #
      if cleanup || passing
        log.info "  Cleaning up slave..."
        remote_cmd(ENV['SLAVE_IP'],"umount /mnt/slave")
        api.snapshot_delete(master_volume_id, snap_id)
        api.volume_detach(ENV['SLAVE_ID'], slave_id)  
        api.volume_delete(slave_id)
      else
        log.info "  FAILED: Not cleaning up to allow for system inspection..."
      end
    end
    log.info "  Cleaning up master..."
    remote_cmd(ENV['MASTER_IP'],"umount /mnt/master")
    api.volume_detach(ENV['MASTER_ID'], master_volume_id)
    api.volume_delete(master_volume_id)

    end_time = Time.now
    log.info "Iterations: #{count} Start:#{start_time} End:#{end_time} Total: #{end_time-start_time}"  
  end 
end
