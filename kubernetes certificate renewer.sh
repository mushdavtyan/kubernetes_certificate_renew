#/bin/bash

: '
This script will renew the all kubernetes certificates.
'


minimum_days="7"




ld=$(tput bold)
underline=$(tput sgr 0 1)
reset=$(tput sgr0)
purple=$(tput setaf 171)
red=$(tput setaf 1)
green=$(tput setaf 76)
tan=$(tput setaf 3)
blue=$(tput setaf 38)

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
	residual_days=`kubeadm certs check-expiration --skip-headers  --skip-log-headers \
	| grep -Ev 'EXPIRES|AUTHORITY|Reading|FYI:' \
	| awk '{print $7}' | sed 's/d/\td/' \
	| sed 's/y/\ty/' | sort -t: -u -k1,1 \
	| grep d | awk '{print $1}' | head -1`
	echo $residual_days
}

forceupdate()
{
	e_warning "There are still $(residual_days_counter_new) days to certificate expiration."
	echo ""
	e_warning "Do you want to force renew kubernetes certificates? [yes/no]"
	read answer
	if [[ "$answer" == "yes" ]]
	then 
		force="yes"
	else
		e_warning "Aborting"
		exit 0
	fi
}


while getopts "k:h:f:" o; do
    case "${o}" in
        k)
            kubeconfig=${OPTARG}
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


if [ -z "${kubeconfig}" ]; then
	e_warning "kubeconfig is /etc/kubernetes/admin.conf"
	echo ""
	echo ""
    kubeconf=/etc/kubernetes/admin.conf
    sleep 1
fi

e_header "Starting the script"
echo ""
sleep 1
node=`kubectl --kubeconfig $kubeconf get nodes --no-headers | head -1 | awk '{print $1}'`
version=`kubectl --kubeconfig $kubeconf get node $node -o jsonpath='{.status.nodeInfo.kubeletVersion}' | sed 's/v//' | tr -d .`
e_success "kubernetes version is `kubectl --kubeconfig $kubeconf get node $node -o jsonpath='{.status.nodeInfo.kubeletVersion}'`"
sleep 1
todayyear=$(date +"%Y")
todaymonth=$(date +"%m")
todayday=$(date +"%d")


e_warning "Certificates will expire after $(residual_days_counter_new) days."


backup_creator()
{
	mkdir -p $HOME/old-certs/pki
	mkdir -p $HOME/old-certs/.kube
	\cp -rp /etc/kubernetes/pki/*.* $HOME/old-certs/pki
	\cp -rp /etc/kubernetes/*.conf $HOME/old-certs
	\cp -rp ~/.kube/config $HOME/old-certs/.kube/.
}


kubelet_restart()
{
  	    systemctl daemon-reload&&systemctl restart kubelet
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
				e_warning "Waiting for kubelet to become active. Try count $checkcount" && sleep 3;
			else
			    e_error "Kubelet state is down. Exiting !!!"
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
	DIFF=$(diff $HOME/old-certs/kubelet.conf /etc/kubernetes/kubelet.conf) 
    if [ "$DIFF" != "" ] 
    then
    	e_success "!! Success. Kubelet config also renewed. Trying to restart kubelet"
    	kubelet_restart
	else
        cd /etc/kubernetes
        mv kubelet.conf $HOME/old-certs/kubelet.conf.bak
        \cp -r admin.conf kubelet.conf	
	         kubelet_restart
	fi
}


kubeconfig_checker()
{
    e_purple "Checking kubeconfig availability and new certificates"
	check=`kubectl --kubeconfig $kubeconf get ns | grep default | awk '{print $1}'`
    if [ "$check" == "default" ]
    then
    	e_success "Kubeconfig is working"
    	sleep 1
	else
        e_error "Kubeconfig is not working. Exiting...."
        exit 1
	fi
}

if [[ "$version" < 1150 ]]
then
	kube_version=old
else
	kube_version=new
fi

if [[ "$kube_version" == "new" ]]
then
	days=$(residual_days_counter_new)
	if [ "$days" -lt "$minimum_days" ] || [[ "$force" == "yes" ]]
	then
		e_purple "Starting certificate update process"
		sleep 1
        backup_creator
        sleep 1
		kubeadm certs renew all > /dev/null 2>&1;
		e_success "alpha certs were updated"
		sleep 1
		cd /etc/kubernetes/
		e_purple "Starting conf file update process"
		kubeadm init phase kubeconfig all > /dev/null 2>&1;
		\cp -r /etc/kubernetes/admin.conf $HOME/.kube/config > /dev/null 2>&1;
		chown $(id -u):$(id -g) $HOME/.kube/config
		sleep 5
        kubelet_checker
        kubeconfig_checker
        days=$(residual_days_counter_new)
        if [[ $days > 300 ]]
        then
        	e_success "All certificates have been renewed"
        	exit 0
        fi	
	else
        e_arrow "There is still $days to certificate expiration"
        echo \n
        e_header "No need to update certificates at this moment"
        echo ""
	fi    
fi

