#!/bin/bash
: '
This script will automatically renew all Kubernetes certificates.
'
##################################################################################################################################
minimum_days="10"                                                    # Minimum days that script will start to renew process
recipient="email@gmail.com"                                          # Notification email address
notify_before="1"                          			     # Count of days, that the script will notify before it start to renew the certificates
yerevan_tommorow_time=`date --date='TZ="Asia/Yerevan" next day'`     # Set your timezone
##################################################################################################################################
notification_days=$(expr $minimum_days + $notify_before)
today=$(date +"%Y-%m-%d")
#Color variables and functions
ld=$(tput bold)
underline=$(tput sgr 0 1)
reset=$(tput sgr0)
purple=$(tput setaf 171)
red=$(tput setaf 1)
green=$(tput setaf 76)
tan=$(tput setaf 3)
blue=$(tput setaf 38)
expired="yes"
e_header() { printf "${bold}${purple}==========  %s  ==========${reset}\n" "$@"
}
e_arrow() { printf "${bold}➜ $@"
}
e_success() { printf "${green}✔ %s${reset}\n" "$@"
}
e_error() { printf "${red}✖ %s${reset}\n" "$@"
}
e_warning() { printf "${tan}➜ %s${reset}\n" "$@"
}
e_underline() { printf "${underline}${bold}%s${reset}\n" "$@"
}
e_purple() { printf "${purple}➜ %s${reset}\n" "$@"
}
e_note() { printf "${underline}${bold}${blue}Note:${reset}  ${blue}%s${reset}\n" "$@"
}
usage()
{
   # Display Help
   e_success "Add description of the script functions here."
   echo ""
   e_success "Syntax: scriptTemplate [-k|f|h]"
   e_success "options:"
   e_purple " h     Print Usage"
   e_purple " k     kubeconfig file"
   e_purple " f     force renew the certificates"
   echo ""
   exit 0
}
internet_connection_result()
{
	if ping -q -c 1 -W 1 google.com >/dev/null > /dev/null 2>&1; then
  		echo "online"
    else
        echo "offline"
    fi
}
internet_connection_checker=$(internet_connection_result)
kubeadm_installer()
{
	if [[ ! -f "/tmp/kubeadm" ]] && [[ "$internet_connection_checker" == "online" ]]; then
		e_success "Downloading the kubeadm"
		curl -L -o /tmp/kubeadm https://dl.k8s.io/release/v1.20.1/bin/linux/amd64/kubeadm --insecure > /dev/null 2>&1;
		chmod +x /tmp/kubeadm
	elif [[ ! -f "/tmp/kubeadm" ]] && [[ "$internet_connection_checker" == "offline" ]]; then
		kubeadm_version=`/usr/bin/kubeadm version -o short | sed -e 's/v1.//' | sed -e 's/..$//'`
		if [[ "$kubeadm_version" -gt "15" ]]; then
			e_success "Using existing kubeadm"
			cp /usr/bin/kubeadm /tmp/kubeadm && chmod +x /tmp/kubeadm
		else
			e_error "Server is offline and kubeadm version is lower than 1.15. Aborting"
			exit 1
		fi
	elif [[ -f "/tmp/kubeadm" ]] && [[ "$internet_connection_checker" == "offline" ]]; then
		chmod +x /tmp/kubeadm
		kubeadm_version=`/tmp/kubeadm version -o short | sed -e 's/v1.//' | sed -e 's/..$//'`
		if [[ "$kubeadm_version" -gt "15" ]]; then
			e_success "Kubeadm version is 1.$kubeadm_version"
		else
			e_error "Server is offline and kubeadm version is lower than 1.15. Aborting"
			exit 1
		fi
	elif [[ -f "/tmp/kubeadm" ]] && [[ "$internet_connection_checker" == "online" ]]; then
		chmod +x /tmp/kubeadm
		kubeadm_version=`/tmp/kubeadm version -o short | sed -e 's/v1.//' | sed -e 's/..$//'`
		if [[ "$kubeadm_version" -gt "15" ]]; then
			e_success "Kubeadm exist, and the version is 1.$kubeadm_version"
		else
			e_success "Kubeadm exist, but the version is 1.$kubeadm_version, downloading the new one"
			rm -rf /tmp/kubeadm
			curl -L -o /tmp/kubeadm https://dl.k8s.io/release/v1.20.1/bin/linux/amd64/kubeadm --insecure > /dev/null 2>&1;
			chmod +x /tmp/kubeadm
		fi
	else
		e_error "cannot set the kubelet"
		exit 1
	fi
}
residual_days_counter_new()
{
	chmod +x /tmp/kubeadm
	residual_days=`/tmp/kubeadm certs check-expiration --skip-headers  --skip-log-headers \
	| grep -Ev 'EXPIRES|AUTHORITY|Reading|FYI:' \
	| awk '{print $7}' | sed 's/d/\td/' \
	| sed 's/y/\ty/' | sort -t: -u -k1,1 \
	| grep d | awk '{print $1}' | head -1` > /dev/null 2>&1;
	if [[ "$residual_days" == *"nval"* ]]; then
		echo "1"
	else
		expired="no"
		echo $residual_days
	fi
}
forceupdate()
{
	e_header "Starting force kubernetes certificates renew process"
	e_success "Checking kubeadm"
	sleep 1
	kubeadm_installer
	sleep 1
	e_warning "There are still $(residual_days_counter_new) days to certificate expiration."
	e_warning "Do you want to force renew kubernetes certificates? [yes/no]"
	read answer
	if [[ "$answer" == "yes" ]]
	then
		force="yes"
	else
		e_warning "Aborting..."
		exit 0
	fi
}
backup_creator()
{
	e_success "Starting the backup process"
	backup_directory="$HOME/kubernetes-backup/$today"
	mkdir -p $backup_directory
	\cp -rp /etc/kubernetes $backup_directory/kubernetes
	\cp -rp /var/lib/kubelet $backup_directory/kubelet
	e_purple "Backup files are stored at $backup_directory"
}
kubelet_restart()
{
	e_purple "restarting the kubelet service"
	systemctl daemon-reload && systemctl restart kubelet
	sleep 5
    servicecheck=`systemctl is-active kubelet`
    if [[ "$servicecheck" != "active" ]]
    then
        sleep 10
		checkcount=10
		while [[ "$servicecheck" != "active" ]];
		do
		checkcount=$((checkcount-1))
		if [[ $checkcount != 0 ]]
		then
			e_success "Waiting for kubelet to become active. Try count $checkcount" && sleep 3
		else
		    e_error "Kubelet state is down. Exiting !!!"
		    echo "!!!! $HOSTNAME kubernetes certificates renew process gone to fail" | mailx -r "$HOSTNAME-cert-renewer@synisys.com ($HOSTNAME)" -s "ERROR!!!! Kubelet state is down on $HOSTNAME. after renewing. Check immediately." $recipient
		    exit 1
		fi
		done
		e_success "Kubelet is ready!"
	else
		e_success "Kubelet is ready!"
	fi
}
kubelet_checker()
{
    e_purple "Checking kubelet service availability and new certificates"
	DIFF=$(diff $backup_directory/kubernetes/kubelet.conf /etc/kubernetes/kubelet.conf)
    if [ "$DIFF" != "" ]
    then
    	e_success "!! Success. Kubelet config also renewed. Trying to restart kubelet"
    	kubelet_restart
	else
        cd /etc/kubernetes
        mv /etc/kubernetes/kubelet.conf $backup_directory/kubernetes/kubelet.conf.bak
        \cp -r /etc/kubernetes/admin.conf /etc/kubernetes/kubelet.conf
	    kubelet_restart
	fi
}
kubeconfig_checker()
{
    e_purple "Checking kubeconfig availability and new certificates"
	check=`kubectl --kubeconfig ~/.kube/config get ns | grep default | awk '{print $1}'`
    if [ "$check" == "default" ]
    then
    	e_success "Kubeconfig is working"
    	sleep 1
    fi
}
apiserver_checker()
{
    e_success "Restarting control plane pods managed by kubeadm"
    /usr/bin/docker ps -af 'name=k8s_POD_(kube-apiserver|kube-controller-manager|kube-scheduler|etcd)-*' -q | /usr/bin/xargs /usr/bin/docker rm -f > /dev/null 2>&1;
	e_success "Waiting for apiserver to be up again"
	until printf "" 2>>/dev/null >>/dev/tcp/127.0.0.1/6443; do sleep 1; done
}
kubeconfig_selector()
{
	if [ -z "${kubeconf}" ]; then
		if [[ -f "/etc/kubernetes/admin.conf" ]]; then
			e_success "kubeconfig is /etc/kubernetes/admin.conf"
		    kubeconf=/etc/kubernetes/admin.conf
		else
			e_error "Cannot find kubeconfig"
			echo "!!!! $HOSTNAME kubernetes certificates renew process gone to fail" | mailx -r "$HOSTNAME-cert-renewer@synisys.com ($HOSTNAME)" -s "ERROR!!!! Cannot find kubeconfig for $HOSTNAME" $recipient > /dev/null 2>&1;
	e_success "Waiting for apiserver to be up again"
	    fi
	fi
}
kube_cert_updater()
{
	e_purple "Starting certificate update process"
	sleep 1
    backup_creator
    sleep 1
	kubeconfig_selector
    sleep 1
    if [[ "$expired" != "yes" ]]; then
		node=`kubectl --kubeconfig $kubeconf get nodes --no-headers | head -1 | awk '{print $1}'`
		version=`kubectl --kubeconfig $kubeconf get node $node -o jsonpath='{.status.nodeInfo.kubeletVersion}' | sed 's/v//' | tr -d .`
		e_success "kubernetes version is $version"
	fi
	sleep 1
    advertise=`cat /etc/kubernetes/kubelet.conf | grep server | awk '{print $2}' | sed -e 's/https:\/\///' | sed -e 's/:6443//'`
    e_purple "Setting the advertise address $advertise"
    sleep 1
    kubeadm_installer
    e_purple "Stopping kubelet service"
    systemctl stop kubelet
    sleep 5
    e_purple "Renewing the certificates"
    /tmp/kubeadm alpha certs renew all > /dev/null 2>&1;
	e_success "alpha certs were updated"
	sleep 1
	e_purple "Starting conf file update process"
	cd /etc/kubernetes
    rm -rf *.conf
    /tmp/kubeadm init phase kubeconfig all --apiserver-advertise-address $advertise > /dev/null 2>&1;
	rm -rf ~/.kube/config
	cp -r /etc/kubernetes/admin.conf ~/.kube/config > /dev/null 2>&1;
	chown $(id -u):$(id -g) ~/.kube/config > /dev/null 2>&1;
	sleep 5
	rm -rf /var/lib/kubelet/pki/kubelet.key
	rm -rf /var/lib/kubelet/pki/kubelet.crt
    kubelet_checker
    apiserver_checker
    if [[ "$expired" != "yes" ]]; then
    	kubeconfig_checker
    fi
    days=$(residual_days_counter_new)
    if [[ $days > 300 ]]
    then
    	e_success "All certificates have been renewed"
    	e_success "Certificates will expire after $days days"
    	echo "SUCCESS!!! $HOSTNAME kubernetes certificates have been renewed successfully" | mailx -r "$HOSTNAME-cert-renewer@synisys.com ($HOSTNAME)" -s "SUCCESS!!! $HOSTNAME kubernetes certificates has been renewed" $recipient > /dev/null 2>&1;
    	exit 0
    else
    	echo "ERROR!!!! $HOSTNAME kubernetes certificates renew process gone to fail" | mailx -r "$HOSTNAME-cert-renewer@synisys.com ($HOSTNAME)" -s "ERROR!!!! Could'nt renew $HOSTNAME kubernetes certificates" $recipient > /dev/null 2>&1;
    fi
}
while getopts "k:h:f" o; do
    case "${o}" in
        k)
            kubeconf=${OPTARG}
            ;;
        h)
            usage
            ;;
        f)
            forceupdate
            ;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))
########################################################################################################################################################################
e_header "Starting the script"
sleep 1
e_warning "Server is $internet_connection_checker.."
sleep 1
kubeadm_installer
if ! command -v mailx &> /dev/null
then
	if [[ "$internet_connection_checker" == "online" ]]; then
		e_purple "Installing mailx on the system"
    	yum install -y mailx > /dev/null 2>&1;
    else
    	e_error "Server is offline, cannot download the mailx to send the mail"
    fi
fi
e_success "Starting the expiration days calculating process"
days=$(residual_days_counter_new)
if [[ "$days" ==  "$notification_days" ]]
then
	e_arrow "There are still $days days to certificate expiration..."
	e_warning "Sending the attention email"
	e_success "Certificates will renew tomorrow at the same time"
	echo "ATTENTION ..  $HOSTNAME certificates will be renewed tommorow at $yerevan_tommorow_time Yerevan time" | mailx -r "$HOSTNAME-cert-renewer@synisys.com ($HOSTNAME)" -s "Tommorow $HOSTNAME kubernetes certificates will renew" $recipient
	exit 0
fi
if [[ "$days" -lt "$minimum_days" ]] || [[ "$force" == "yes" ]]
then
	kube_cert_updater
else
	e_arrow "There are still $days days to certificate expiration"
	echo ""
	e_header "No need to update certificates at this moment"
	exit 0
fi
#/sbin/iptables-save > /tmp/iptables.txt
#/sbin/iptables -A INPUT -p tcp --dport 22 -j ACCEPT
#/sbin/iptables -A OUTPUT -p tcp --sport 22 -j ACCEPT
#/sbin/iptables -A INPUT -s 172.0.0.0/8 -j ACCEPT
#/sbin/iptables -A OUTPUT -d 172.0.0.0/8 -j ACCEPT
#/sbin/iptables -A INPUT -j DROP
#/sbin/iptables -A OUTPUT -j DROP
#/sbin/iptables-restore < /tmp/iptables.txt
#date -s "24 JUL 2022 16:08:40"
#find /etc/kubernetes/pki/ -type f -name "*.crt" -print|egrep -v 'ca.crt$'|xargs -L 1 -t  -i bash -c 'openssl x509  -noout -text -in {}|grep After'
