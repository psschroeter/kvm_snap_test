require 'time'
class VirshAPI

  def initialize(logger)
    @logger = logger
  end

  def cmd(command)
    puts command
    ret = `#{command}`
    unless $?.success?
      raise "command failure #{$?}" 
    end
    ret
  end

  def vol_path(vol_name)
    volumes = cmd("virsh vol-list #{pool}").chomp.split("\n")[2..-1]
    vol_map = {}
    volumes.each do |v|
      (name, path) = v.split
      vol_map[name] = path
    end
    unless vol_map.key?(vol_name)
      raise "Can not find volume in virsh vol-list #{pool}"
    end
    vol_map[vol_name]
  end

  def device_name
    "vda"
  end

  def pool
    "default"
  end

  def volume_create(vol_name)
    #cmd("virsh vol-create-as #{pool} vol1 1G --format raw --backing-vol ?? --backing-vol-format qcow2 --allocation 1G")
    out = cmd("virsh vol-create-as #{pool} #{vol_name} 1G --format qcow2")
    if out =~ /Vol (.*) created/
      return $1
    else
      raise "unknown output #{out}"
    end
  end
  def volume_delete(vol_name)
    out = cmd("virsh vol-delete #{vol_name} --pool #{pool}")
    unless out =~ /deleted/
      raise "delete failed: #{out}"
    end
  end

  def volume_attach(dom_name, vol_name)
    out = cmd("virsh attach-disk #{dom_name} #{vol_path(vol_name)} #{device_name} --driver qemu --subdriver qcow2")
    unless out =~ /success/
      raise "attach failed: #{out}"
    end
  end
  def volume_detach(dom_name, vol_name)  
    out = cmd("virsh detach-disk #{dom_name} #{vol_path(vol_name)}")
    unless out =~ /success/
      raise "dettach failed: #{out}"
    end
  end

  # output = stdout from `cat /proc/partitions`
  def get_current_devices(output)
    lines = output.split("\n")
    partitions = lines.drop(2).map do |line|
      line.chomp.split.last
    end
    partitions.reject! do |partition|
      partition =~ /^dm-\d/
    end
    devices = partitions.select do |partition|
      partition =~ /[a-z]$/
    end
    devices.sort!.map! {|device| "/dev/#{device}"}
    if devices.empty?
      devices = partitions.select do |partition|
        partition =~ /[0-9]$/
      end.sort.map {|device| "/dev/#{device}"}
    end
    devices
  end

  def volume_create_from_snap(source_vol, target_vol, snap_id)
    cmd("qemu-img convert -f qcow2 -O qcow2 -s '#{snap_id}' '#{vol_path(source_vol)}' '/var/lib/libvirt/images/#{target_vol}'")
    cmd("chown qemu.qemu /var/lib/libvirt/images/#{target_vol}")
    cmd("chmod 0600 /var/lib/libvirt/images/#{target_vol}")
    cmd("virsh pool-refresh default")
    target_vol
  end

#  if $qemu_img info "$source_img" | grep -q backing; then
#    qemu-img convert -O qcow2 source_img dest_img
## create_from_file() {
#  local volfs=$1
#  local volimg="$2"
#  local volname=$3
#  if [ -b $volimg ]; then
#      $qemu_img convert -f raw -O qcow2 "$volimg" /$volfs/$volname
#  else
#    # if backing image exists, we need to combine them, otherwise
#    # copy the image to preserve snapshots/compression
#    if $qemu_img info "$volimg" | grep -q backing; then
#      $qemu_img convert -f qcow2 -O qcow2 "$volimg" /$volfs/$volname >& /dev/null
#    else
#      cp -f $volimg /$volfs/$volname
#    fi  
#  fi  
#··
#  if [ "$cleanup" == "true" ]
#  then
#    rm -f "$volimg"
#  fi  
#  chmod a+r /$volfs/$volname
#}

  def snapshot_create(vol_name)
    snap_name = Time.now.to_i
    cmd(%(qemu-img snapshot -c "#{snap_name}" #{vol_path(vol_name)}))
    snap_name
  end
  def snapshot_delete(vol_name, snap_name)
    cmd(%(qemu-img snapshot -d "#{snap_name}" #{vol_path(vol_name)}))
  end
end
