#!/bin/bash

: '
This script will automatically renew all Kubernetes certificates.
'

minimum_days="10"
recipient="mushegh.davtyan@synisys.com"
notification_days=$(expr $minimum_days + 1)



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

residual_days_counter_new()
{
	if [[ ! -f "/tmp/kubeadm" ]]; then
		curl -L -o /tmp/kubeadm https://dl.k8s.io/release/v1.20.1/bin/linux/amd64/kubeadm --insecure > /dev/null 2>&1;
	    chmod +x /tmp/kubeadm
	fi
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


while getopts "k:h:f:" o; do
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


e_header "Starting the script"
sleep 1
if [ -z "${kubeconf}" ]; then
	if [[ -f "/etc/kubernetes/admin.conf" ]]; then
		e_warning "kubeconfig is /etc/kubernetes/admin.conf"
	    kubeconf=/etc/kubernetes/admin.conf
	else
		echo "Cannot find kubeconfig"
		echo "!!!! $HOSTNAME kubernetes certificates renew process gone to fail" | mailx -r "$HOSTNAME-cert-renewer@synisys.com ($HOSTNAME)" -s "ERROR!!!! Cannot find kubeconfig for $HOSTNAME" $recipient

		exit 1
    fi
    sleep 1
fi

todayyear=$(date +"%Y")
todaymonth=$(date +"%m")
todayday=$(date +"%d")
yerevan_tommorow_time=`date --date='TZ="Asia/Yerevan" next day'`


if ! command -v mailx &> /dev/null
then
	e_purple "Installing mailx on the system"
    yum install -y mailx > /dev/null 2>&1;
fi


backup_creator()
{
	e_success "Starting the backup process"
	backup_directory="$HOME/kubernetes-backup/$todayyear-$todaymonth-$todayday"
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
	else
        e_error "Kubeconfig is not working. Exiting...."
        echo "!!!! $HOSTNAME kubernetes certificates renew process gone to fail" | mailx -r "$HOSTNAME-cert-renewer@synisys.com ($HOSTNAME)" -s "ERROR!!!! Kubeconfig is not working for $HOSTNAME" $recipient
        exit 1
	fi
}

apiserver_checker()
{
    e_success "Restarting control plane pods managed by kubeadm"
    /usr/bin/docker ps -af 'name=k8s_POD_(kube-apiserver|kube-controller-manager|kube-scheduler|etcd)-*' -q | /usr/bin/xargs /usr/bin/docker rm -f > /dev/null 2>&1;
	e_success "Waiting for apiserver to be up again"
	until printf "" 2>>/dev/null >>/dev/tcp/127.0.0.1/6443; do sleep 1; done
}


kube_cert_updater()
{
	e_purple "Starting certificate update process"
	sleep 1
    backup_creator
    sleep 1
    if [[ "$expired" != "yes" ]]; then
		node=`kubectl --kubeconfig $kubeconf get nodes --no-headers | head -1 | awk '{print $1}'`
		version=`kubectl --kubeconfig $kubeconf get node $node -o jsonpath='{.status.nodeInfo.kubeletVersion}' | sed 's/v//' | tr -d .`
		e_success "kubernetes version is `kubectl --kubeconfig $kubeconf get node $node -o jsonpath='{.status.nodeInfo.kubeletVersion}'`"
	fi
	sleep 1
    advertise=`cat /etc/kubernetes/kubelet.conf | grep server | awk '{print $2}' | sed -e 's/https:\/\///' | sed -e 's/:6443//'`
    e_purple "Setting the advertise address $advertise"
    sleep 1
	if [[ ! -f "/tmp/kubeadm" ]]; then
		e_purple "Downloading the kubeadm"
		curl -L -o /tmp/kubeadm https://dl.k8s.io/release/v1.20.1/bin/linux/amd64/kubeadm --insecure > /dev/null 2>&1;
	    chmod +x /tmp/kubeadm
	fi
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

days=$(residual_days_counter_new)

if [[ "$days" ==  "$notification_days" ]]
then
	echo "ATTENTION ..  $HOSTNAME certificates will be renewed tommorow at $yerevan_tommorow_time Yerevan time" | mailx -r "$HOSTNAME-cert-renewer@synisys.com ($HOSTNAME)" -s "Tommorow $HOSTNAME kubernetes certificates will renew" $recipient
    e_arrow "There is still $days days to certificate expiration..."
	echo \n
	e_header "Certificates will renew tomorrow at the same time"
	exit 0
fi


if [[ "$days" -lt "$minimum_days" ]] || [[ "$force" == "yes" ]]
then
	kube_cert_updater
else
	e_arrow "There is still $days days to certificate expiration"
	echo \n
	e_header "No need to update certificates at this moment"
	exit 0
fi
