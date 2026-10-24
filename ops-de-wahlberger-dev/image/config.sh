#!/bin/bash
# Based on openSUSE:Factory/kiwi-templates-Minimal config.sh (MIT, (c) SUSE LLC); see README.md.
# Lines/blocks changed vs upstream are marked "HETZNER:". Upstream branches that only apply to
# profiles we dropped (s390x, ppc64le, RaspberryPi, HyperV, sdbootutil/BLS) are removed.
#======================================
# Functions...
#--------------------------------------
test -f /.kconfig && . /.kconfig
test -f /.profile && . /.profile

set -euxo pipefail

#======================================
# Greeting...
#--------------------------------------
echo "Configure image: [$kiwi_iname]-[$kiwi_profiles]..."

#======================================
# add missing fonts
#--------------------------------------
# Systemd controls the console font now
echo FONT="eurlatgr.psfu" >> /etc/vconsole.conf

#======================================
# prepare for setting root pw, timezone
#--------------------------------------
echo "** reset machine settings"
rm -f /etc/machine-id \
      /var/lib/zypp/AnonymousUniqueId \
      /var/lib/systemd/random-seed

#======================================
# Specify default systemd target
#--------------------------------------
baseSetRunlevel multi-user.target

#======================================
# Import trusted rpm keys
#--------------------------------------
suseImportBuildKey

#======================================
# Enable sshd
#--------------------------------------
systemctl enable sshd.service

if [ -e /etc/cloud/cloud.cfg ]; then
        systemctl enable cloud-init-local
        systemctl enable cloud-init
        systemctl enable cloud-config
        systemctl enable cloud-final
fi

# HETZNER: upstream enables jeos-firstboot (interactive wizard) here if installed. It is not
# installed in this image. Without it nothing else would suppress systemd-firstboot, which
# prompts for locale/timezone/root password on the console at the first boot (machine-id was
# removed above), so mask it. Defaults (en_US.UTF-8, UTC) are already in the image.
systemctl mask systemd-firstboot.service

# HETZNER: no password login anywhere. Root is locked; the only account is the one cloud-init
# creates from Hetzner's user-data (key-only, see root/etc/ssh/sshd_config.d).
passwd -l root

# Enable NetworkManager if installed
if rpm -q --whatprovides NetworkManager >/dev/null; then
        systemctl enable NetworkManager.service
fi

#======================================
# Add repos from control.xml
#--------------------------------------
if rpm -q live-add-yast-repos; then
	add-yast-repos
	zypper --non-interactive rm -u live-add-yast-repos
fi

#=====================================
# Enable chrony if installed
#-------------------------------------
if [ -f /etc/chrony.conf ]; then
	systemctl enable chronyd
fi

cat >/etc/fstab.script <<"EOF"
#!/bin/sh
set -euxo pipefail
# Add umask=0077 to the ESP (boo#1250510)
gawk -i inplace '$2 == "/boot/efi" && $4 == "defaults" { $4 = $4",umask=0077" } { print $0 }' /etc/fstab
# Ensure it's present
gawk '$2 == "/boot/efi" { if ($4 !~ /umask=0077/) exit(1); }' /etc/fstab
EOF

chmod a+x /etc/fstab.script

#======================================
# Add default kernel boot options
#--------------------------------------
consoles='console=ttyS0,115200 console=tty0'

cmdline=('rw' 'quiet' 'systemd.show_status=1' ${consoles})

# Configure SELinux if installed
# Note: Because of https://github.com/OSInside/kiwi/issues/2709, the root filesystem
# isn't fully labelled, but the first system snapshot is created after autorelabel
# so this is never visible.
if [[ -e /etc/selinux/config ]]; then
	cmdline+=('security=selinux' 'selinux=1')

	sed -i -e 's|^SELINUX=.*|SELINUX=enforcing|g' \
	       -e 's|^SELINUXTYPE=.*|SELINUXTYPE=targeted|g' \
	       "/etc/selinux/config"

	# HETZNER: ask selinux-autorelabel (dracut module, part of patterns-base-selinux) to
	# relabel the whole filesystem once in the initrd of the first boot. Upstream gets
	# its labelled state through the jeos-firstboot flow, which we do not have. The marker
	# is removed by the relabel service when done.
	mkdir -p /etc/selinux
	touch /etc/selinux/.autorelabel
fi

if [ -e /etc/default/grub ]; then
	sed -i "s#^GRUB_CMDLINE_LINUX_DEFAULT=.*\$#GRUB_CMDLINE_LINUX_DEFAULT=\"${cmdline[*]}\"#" /etc/default/grub
else
	echo "Unknown bootloader"
	exit 1
fi

# if /etc/zypp/zypp.conf exists, patch it - otherwise rely on packages providing functionality
if [ -f /etc/zypp/zypp.conf ]; then
	#======================================
	# Disable recommends on virtual images (keep hardware supplements, see bsc#1089498)
	#--------------------------------------
	sed -i 's/.*solver.onlyRequires.*/solver.onlyRequires = true/g' /etc/zypp/zypp.conf

	#======================================
	# Disable installing documentation
	#--------------------------------------
	sed -i 's/.*rpm.install.excludedocs.*/rpm.install.excludedocs = yes/g' /etc/zypp/zypp.conf
fi
