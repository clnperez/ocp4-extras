#!/usr/bin/bash

DEBUG=1

# PS4 Prompt for debugging:
PS4='$(tput setaf 3)$(printf "%-12s %.3fs #%s: " $(date +%H:%M:%S-%Z) $(echo $(date "+%s.%3N")-'$(date "+%s.%3N")' | bc ) $LINENO)$(tput sgr0)'
# Use "set -x" to print commands and their arguments as they are executed (for debug).
# set -x
set +x 

# @ TODO: These values need to be configurable in a better way: proc, mem, proctype ...
proc=0.5
proc_type=shared
mem=16
# skip_create b=bootstrap only; bc= bootstrap, control plane; bcw=bootstrap, control plane and workers (all nodes)
skip_create=b

ibm_cloud_endpoint_base_url="cloud.ibm.com"

# Display command usage information
function usage() {
    echo "Create VMs needed for a cluster. Uses the values specified in install-config.yaml."
    echo "Refer to the README in the this directory for more information."
    echo "Usage:"
    echo "ocp_install [command]"
    echo
    echo "Available commands:"
    echo "start           Start the cluster install process. It is the default command"
    echo "bootstrap-wait  Continue after a timeout waiting for bootstrapping."
    echo "teardown        Cleanup the previous install-config"
    echo "restart         Cleanup the previous install-config and restart the install process"
    echo "-h, --help      Display this message"
    echo
    echo "Optional Environment Variables: PPC_OCP_BASE_DIR=\"path_name\", PPC_OCP_DEBUG=[y|n]"
    echo "If something goes wrong, use the restart command. DO NOT run \`start\` twice."
    echo "Make sure you have backed up your config files. the openshift-install command will delete install-config.yaml"
    echo "It is recommended that you save the output of your install to a local file. The default kubeadmin password"
    echo "  will be output at the end of a successful install."

}

# Check a directory's existence
# $1 Directory path to check
function directory_must_exist() {
    if [ ! -d "$1" ]; then
        echo "directory not found: $1. Exiting."
        exit 1
    fi
}

# Check a file's existence
# $1 File path to check
function file_must_exist() {
    if [ -z "$debug" ]; then
	    env | grep OCP
    fi
    if [ ! -f "$1" ]; then
        echo "file not found: $1. Exiting."
        exit 1
    fi
}

# Get value of an OCP config field from helper node vars file
# $1 Variable to set
# $2 OCP field name
function get_val_from_vars_file() {
    local -n ret="$1"
    ret=$(yq "$2" $PPC_OCP_VARS)
}

# Sleep wrapper
# $1 Number of minutes to wait
# $2 Message to display
function sleepmin() {
    echo "Sleeping $1 min: $2"
    sleep $(($1 * 60))
}

# Create a single VM
# $1 VM Name
# $2 user-data
function create_vm() {

    set -x
    if [[ -z $ssh_key_name || $ssh_key_name = "null" ]]; then
        echo "creating $1 without ssh_key"
	inst_id=$(ibmcloud pi ins cr --json $1 --sys-type $sys_type --processor-type $proc_type --processors $proc --memory=$mem --storage-tier $storage_tier --user-data $2 --image $rhcos_image_name  --subnets $helper_subnet_id | jq -r '.[].pvmInstanceID')
        rc=$?
    else
        echo "creating $1 with ssh_key"
	inst_id=$(ibmcloud pi ins cr --json $1 --sys-type $sys_type --processor-type $proc_type --processors $proc --memory=$mem--storage-tier $storage_tier --key-name $ssh_key_name --user-data $2 --image $rhcos_image_name  --subnets $helper_subnet_id | jq -r '.[].pvmInstanceID')
        rc=$?
    fi

    if [ $rc != 0 ]; then
        echo "create VM command for $1 failed with return code $rc. Exiting."
        exit 1
    fi

    printf "Waiting for VM to finish building...\n"
    sleep 90
    echo "Sending an immediate shutdown command to the VM to allow helper node configuration..."
    shutdown=0
    for i in {1..5} ; do
	   vm_state=$(ibmcloud pi ins get "$inst_id" --json | jq -r '.status')
	   if [ "$?" == 0 ]  && [ "$vm_state" != "BUILD" ]; then
           ibmcloud pi instance action -o immediate-shutdown $inst_id
	   shutdown=1
           break
	fi
	sleep 30
    done
    if [ "$shutdown" != 1 ]; then
	    echo "unable to shut down $vm_name". Exiting
	    exit 1
    fi
    sleep 45
    vm_state=$(ibmcloud pi ins get "$inst_id" --json | jq -r '.status')
    if [ "$vm_state" != "SHUTOFF" ] ; then
	    echo "VM $vm_name did not sucessfully shut down. Exiting"
	    exit 1
    fi

    set +x
    return 0
}

# waiting for IPs to be available for a group of new created vms
function update_node_configs() {
    echo "copy running config files into $PPC_OCP_TEMP_DIR tmp dir..."
    rm $PPC_OCP_TEMP_DIR/zonefile.db
    rm $PPC_OCP_TEMP_DIR/reverse.db
    rm $PPC_OCP_TEMP_DIR/haproxy.cfg
    rm $PPC_OCP_TEMP_DIR/dhcpd.conf

    cp /var/named/zonefile.db $PPC_OCP_TEMP_DIR/.
    cp /var/named/reverse.db $PPC_OCP_TEMP_DIR/.
    cp /etc/haproxy/haproxy.cfg $PPC_OCP_TEMP_DIR/.
    cp /etc/dhcp/dhcpd.conf $PPC_OCP_TEMP_DIR/.
    #echo "vm_ip_changed $vm_ip_changed" boolean right? remove this debug 
    names=("$@")
    for (( loop=0; loop < 10; loop++ )); do
        found="false"
        for  i in "${!names[@]}"; do
            update_config_for_vm "${names[$i]}"
            if [ $? == 0 ]; then
                unset names[$i]
                break
            else
                continue
            fi
        done
        if [ ${#names[@]} == 0 ]; then
            return 0
        fi
        sleep 1
    done
    echo "Unable to retrieve IP address for VM ${names[@]} after timeout"
    exit 1
}

# Check if we can get the IP of a new created VM.
# If yes, update all related files with new IP.
# $1 VM name
function update_config_for_vm() {
    vm_name=$1
    inst_id=$(ibmcloud pi instance list --json |  jq -r ".pvmInstances[] | select(.name==\"$vm_name\").id")
    if [ -z "$inst_id" ]; then
        echo "cannot get instance id for VM $1"
        return 1
    fi
    vm_info=$(ibmcloud pi instance get --json $inst_id)
    if [ $DEBUG ]; then
	    printf "VM $vm_name INFO \n: $vm_info\n"
    fi
    ip_address=$(echo $vm_info | jq -r '.addresses[0].ipAddress')
    mac_address=$(echo $vm_info | jq -r '.addresses[0].macAddress')
    if [[ -z $ip_address || $ip_address == "null" ]]; then
        echo "cannot get ip address for VM $vm_name. Exiting"
        return 1
    fi
    # beside checking the IP address, should we also make sure if the VM is in available state?
    if [ "$ip_address" == "0.0.0.0" ]; then
        echo "ip address for VM $1 not assigned. Exiting"
        return 1
    fi
    vm_name_with_domain="$1.$cluster_id.$dns_domain"
    dns_ip_address=$(nslookup $vm_name_with_domain | grep "Address: "| awk '{print $2}')
    if [ -z "$dns_ip_address" ]; then
        echo "dns_ip_address is empty"
        exit 1
    fi
    if [ "$dns_ip_address" == "$ip_address" ]; then
        echo "VM ip and dns ip are the same"
        echo "vm_ip_changed $vm_ip_changed"
        return 0
    fi
    echo "ip assigned for $1"
    sed -i "s/$dns_ip_address/$ip_address/" $PPC_OCP_TEMP_DIR/zonefile.db
    sed -i "s/$dns_ip_address/$ip_address/" $PPC_OCP_TEMP_DIR/haproxy.cfg
    sed -i "s/$(echo $dns_ip_address|cut -d . -f 4)\tIN\tPTR\t$1/$(echo $ip_address|cut -d . -f 4)\tIN\tPTR\t$1/" $PPC_OCP_TEMP_DIR/reverse.db
    old_dhcp_info=$(grep "host $vm_name" "$PPC_OCP_TEMP_DIR/dhcpd.conf")
    sed -i "s/$old_dhcp_info/host $vm_name { hardware ethernet $mac_address; fixed-address $ip_address; }/" "$PPC_OCP_TEMP_DIR/dhcpd.conf"
    restore_changed_files "$PPC_OCP_TEMP_DIR"
    vm_ip_changed="true"
    echo "IP configured for $vm_name: (vm_ip_changed) $vm_ip_changed"
    return 0
}

# Log in to ibmcloud
function login_ibmcloud() {
    ibmcloud login -a "https://$ibm_cloud_endpoint_base_url" --apikey "$ibm_cloud_api_key" --no-region
    rc=$?
    if [ $rc != 0 ]; then
        echo "login to ibm cloud command failed with exit code $rc"
        exit 1
    fi
    ibmcloud pi ws tg $ibm_cloud_workspace_crn
    rc=$?
    if [ $rc != 0 ]; then
        echo "target workspace command failed with exit code $rc"
        exit 1
    fi
    return 0
}

# Restore zonefile.db, reverse.db and haproxy.cfg
# $1 Directory the files are restored from
# $1 Directory the files are restored from
function restore_changed_files() {
  echo "Restore changed files from $1"
  cp "$1/zonefile.db" /var/named/zonefile.db
  cp "$1/reverse.db" /var/named/reverse.db
  cp "$1/haproxy.cfg" /etc/haproxy/haproxy.cfg
  cp "$1/dhcpd.conf" /etc/dhcp/dhcpd.conf

  # Restore default SELinux security contexts
  restorecon /var/named/zonefile.db
  restorecon /var/named/reverse.db
  restorecon /etc/haproxy/haproxy.cfg
  restorecon /etc/dhcp/dhcpd.conf

  # Restart associated services
  set -x
  systemctl daemon-reload
  systemctl restart named.service
  systemctl restart haproxy.service
  systemctl restart dhcpd.service
  set +x
}

# Doing the install prepare work
function prepare_install() {
    # cleanup old install dir
    rm -rf $PPC_OCP_INSTALL_DIR

    # prepare install dir
    mkdir $PPC_OCP_INSTALL_DIR
    cp $PPC_OCP_DATA/install-config.yaml $PPC_OCP_INSTALL_DIR

    if ! type "resolvectl" > /dev/null; then
        echo "resolvectl not installed. Exiting."
        exit 1
    fi

    sudo resolvectl flush-caches

    # create ign files
    cic_output=$(openshift-install $INSTALL_OPTS create ignition-configs --dir $PPC_OCP_INSTALL_DIR)x
    rc=$?
    # this doesn't always return failure if validation checks fail
    if [ "$rc" != 0 ] || [ grep "ERROR" "${cic_output}x" ] ; then
        echo "Failed to generate ignition config files. Exiting. RC=$?"
        exit 1
    fi
    cp $PPC_OCP_INSTALL_DIR/*.ign /var/www/html/ignition/
    restorecon -vR /var/www/html/
    chmod o+r /var/www/html/ignition/*.ign

    # login ibmcloud
    login_ibmcloud

    #update the name server
    printf "Setting the nameserver of the workspace subnet to the helper node IP"
    ibmcloud pi snet upd $helper_subnet_id -d $helper_ip
    echo "updated the DNS for network $helper_subnet_id"
}

# Create the bootstrap node
function create_bootstrap() {
    # create bootstrap
    user_data_txt="{\"ignition\":{\"config\":{\"merge\":[{\"source\": \"http://$helper_ip:8080/ignition/bootstrap.ign\"}]}, \"version\": \"3.2.0\"}}"
    echo "$user_data_txt" > $PPC_OCP_TEMP_DIR/bootstrap_user_data.txt
    cat $PPC_OCP_TEMP_DIR/bootstrap_user_data.txt
    user_data=@$PPC_OCP_TEMP_DIR/bootstrap_user_data.txt
    get_val_from_vars_file vm_name ".bootstrap.name"
    date
    echo "before creating VM $vm_name"
    echo "user_data is $user_data"
    echo "sys_type is $sys_type"
    vm_ip_changed="false"
    create_vm "$vm_name" "$user_data"
    bootstrapnames=( "$vm_name" )
    update_node_configs "${bootstrapnames[@]}"
    echo "vm_ip_changed $vm_ip_changed"
    start_vm $vm_name
    return 0
}

# Create the control plane nodes
function create_control_plane_nodes() {
    user_data=@$PPC_OCP_INSTALL_DIR/master.ign
    get_val_from_vars_file num_control_plane_nodes '.masters | length'
    vm_ip_changed="false"
    for (( c=0; c < $num_control_plane_nodes; c++ )); do
        get_val_from_vars_file vm_name ".masters[$c].name"
        create_vm "$vm_name" "$user_data"
        control_plane_node_names[$c]="$vm_name"
    done
    update_node_configs "${control_plane_node_names[@]}"
    if [ "$vm_ip_changed" == "false" ]; then
        sleepmin 6 "to wait for the last control_plane_node to be ready"
    #else
    #    sleepmin 7 "to wait for the last control_plane_node to be ready"
    fi
    for (( c=0 ; c < $num_control_plane_nodes; c++)); do
        node_name="${control_plane_node_names[$c]}"
        echo "starting control plane node $node_name"
        start_vm $node_name
    done
    date
    return 0
}

# Wait for the bootstrap to complete the install process
function wait_for_bootstrap_complete() {
    openshift-install $INSTALL_OPTS wait-for bootstrap-complete --dir $PPC_OCP_INSTALL_DIR
    rc=$?
    if [ $rc != 0 ]; then
        echo "waiting for bootstrap complete command failed with exit code $rc"
	echo "If bootstrapping seems to be continueing (check progress on worker nodes),"
	echo "re-run this script with the bootstrap-wait command."
        return 2
    fi
}

# Create the worker nodes
function create_worker_nodes() {
    user_data=@$PPC_OCP_INSTALL_DIR/worker.ign
    get_val_from_vars_file num_workers '.workers | length'
    vm_ip_changed="false"
    printf "creating $num_workers worker nodes...\n"
    for (( c=0; c < $num_workers; c++ )); do
        get_val_from_vars_file vm_name ".workers[$c].name"
        create_vm "$vm_name" "$user_data"
	if [ $? != 0 ]; then
		printf "Error creating VM. Resolve and either cleanup and start again, or delete any workers and retry from bootstrap phase.\n"
		exit 1
	fi
        worker_node_names[$c]="$vm_name"
    done
    update_node_configs "${worker_node_names[@]}"

    if [ "$vm_ip_changed" == "false" ]; then
        sleepmin 7 "to wait for the last worker to configure"
    else
        sleepmin 10 "to wait for the last worker to configure"
    fi
    printf "restarting worker nodes...\n"
    for (( c=0; c < $num_workers; c++ )); do
        node_name="${worker_node_names[$c]}"
        start_vm $node_name
        echo "started $node_name"
    done
}

# param 1: vm_name
function start_vm() {

    vm_name=$1
    inst_id=$(ibmcloud pi instance list --json |  jq -r ".pvmInstances[] | select(.name==\"$vm_name\").id")
    if [ -z "$inst_id" ]; then
        echo "cannot get instance id for VM $vm_name"
        return 1
    fi

    if [ "$DEBUG" ] ; then
        printf "starting instance $vm_name ($inst_id)\n"
    fi

    ibmcloud pi ins act -o start $inst_id
    rc=$?
    if [ $rc != 0 ]; then
        echo "VM $vm_name was not sucessfully started"
        return $rc
    fi
    sleep 5
    return 0
}
# Wait for the install process to complete
function wait_install_complete() {
    # TODO: The CSR approval needs to move out and keep running during the worker node finalization
    export KUBECONFIG=$PPC_OCP_INSTALL_DIR/auth/kubeconfig
    oc get csr | grep -i pending
    oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | xargs --no-run-if-empty oc adm certificate approve
    sleepmin 10 "wait for worker CSRs"
    oc get csr | grep -i pending
    oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | xargs oc adm certificate approve
    printf "in another terminal, run the following command occasionally until all the worker nodes are in Ready state:\n"
    printf "oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | xargs oc adm certificate approve\n"
    openshift-install $INSTALL_OPTS --dir $PPC_OCP_INSTALL_DIR wait-for install-complete
    if [ $DEBUG ] ; then
        printf "In another terminal, watch the progression of: oc get clusteroperator\n"
    fi
}

# Delete VMs during the cleanup process
# $@ List of VMs names to delete
function delete_vms() {
    names=("$@")
    for i in "${!names[@]}"; do
        inst_id=$(ibmcloud pi instance list --json |  jq -r ".pvmInstances[] | select(.name==\"${names[$i]}\").id")
        if [ -z "$inst_id" ]; then
            echo "cannot get instance id for VM ${names[$i]}"
            continue
        fi
        set -x
        ibmcloud pi ins del ${names[$i]}
        set +x
    done
}

# Check status for a deleted VM during the cleanup process
# $1 Name of the VM to check
function check_vm_del_status() {
    inst_id=$(ibmcloud pi instance list --json |  jq -r ".pvmInstances[] | select(.name==\"$1\").id")
    if [ -z "$inst_id" ]; then
        echo "cannot get instance id for VM $1"
        return 0
    fi
    set -x
    status=$(ibmcloud pi instance get ${inst_id} --json |  jq -r '.status')
    set +x
    if [ "$status" == "ERROR" ]; then
        ibmcloud pi del $1
        sleep 10
        return 1
    fi
    ibmcloud pi ins get $inst_id
    if [ $? != 0 ]; then
        echo "VM $1 is deleted"
        return 0
    fi
    return 1
}

# Start the ocp install process from scratch
function start_install() {
    prepare_install

    vm_ip_changed="false"
    echo "vm_ip_changed $vm_ip_changed"
    for_control_plane="false"
    create_bootstrap
    for_control_plane="true"
    create_control_plane_nodes
    if [ $? == 0 ]; then
        wait_for_bootstrap_complete
    fi
    if [ $? == 0 ]; then
        continue_install
    else
	printf "Bootstrap phase did not complete. If it timed out you can try re-running with the waitfor-bootstrap command.\n"
	exit 1
    fi
}

# Retry the ocp install process after a bootstrap timeout
# Also could be used if any changes needed to be manually made
function start_from_bootstrap() {
    wait_for_bootstrap_complete
    if [ $? == 0 ]; then
        continue_install
    else
	printf "Bootstrap phase did not complete.\n"
	exit 1
    fi
}

# $1 bootstrap name from vars file
function delete_bootstrap_node {

    printf "Bootstrap successful. Deleting unneeded bootstrap VM"
    get_val_from_vars_file bootstrap_name ".bootstrap.name"
    delete_vms $bootstrap_name

    # todo: for now, not retrying
    # if delete failed the user can delete it manually
}

# continue after the bootstrap phase completed
function continue_install() {
    for_control_plane="false"
    delete_bootstrap_node
    create_worker_nodes
    wait_install_complete
    if [[ $? == 2 && $need_retry == "true" ]]; then
        need_retry="false"
        login_ibmcloud
        echo "The install failed to complete. start the cleanup procedure and retry the install process one time"
        restart "false"
        exit $?
    fi
    exit $?
}

# Cleanup the old install-config
# $1 Boolean
function cleanup() {
    declare -a node_names
    get_val_from_vars_file bootstrap_name ".bootstrap.name"
    node_names=("$bootstrap_name")
    get_val_from_vars_file num_control_plane_nodes '.masters | length'
    for (( c=0; c < $num_control_plane_nodes; c++ )); do
        get_val_from_vars_file vm_name ".masters[$c].name"
        node_names+=("$vm_name")
    done
    if [ "$1" == "true" ]; then
        get_val_from_vars_file num_worker_nodes '.workers | length'
        for (( c=0; c < $num_worker_nodes; c++ )); do
            get_val_from_vars_file vm_name ".workers[$c].name"
            node_names+=("$vm_name")
        done
    fi
    delete_vms "${node_names[@]}"
    return $?
}

# Cleanup the old install-config and restart the install process
# $1 Boolean
function restart() {
    echo "deleting VMs and restarting the install process"
    sleep 5
    cleanup $1
    if [ $? == 0 ]; then
        sleepmin 2 "Waiting for caches to clear for name re-use"
        start_install
        if [ $? == 0 ]; then
            return 0
        else
            echo "openshift installation failed"
            return 1
        fi
    fi
    echo "cleanup before restarting failed. need to do manual cleanup"
    return 1
}

# Check the pre condition of the install env
function precheck() {
    # checking if env variable PPC_OCP_BASE_DIR is defined
    if [ -z "$PPC_OCP_BASE_DIR" ]; then
        echo "environment variable PPC_OCP_BASE_DIR is not defined. Using pwd"
	PPC_OCP_BASE_DIR=`pwd`
	sleep 2
    fi
    echo "PPC_OCP_BASE_DIR=$PPC_OCP_BASE_DIR"

    # Some directories and files
    PPC_OCP_INSTALL_DIR="$PPC_OCP_BASE_DIR/install"
    PPC_OCP_TEMP_DIR="$PPC_OCP_BASE_DIR/temp"
    PPC_OCP_BACKUP="$PPC_OCP_BASE_DIR/backup"
    PPC_OCP_DATA="$PPC_OCP_BASE_DIR/data"
    PPC_OCP_VARS="$PPC_OCP_DATA/vars-ppc64le.yaml"

    echo "setting KUBECONFIG environment variable"
    export KUBECONFIG=$PPC_OCP_INSTALL_DIR/auth/kubeconfig
    # checking if ocp, data directories and files are there
    directory_must_exist "$PPC_OCP_BASE_DIR"
    if [[ $command != "start" ]] ; then
        directory_must_exist "$PPC_OCP_DATA"
    fi
    file_must_exist "$PPC_OCP_VARS"
    file_must_exist "$PPC_OCP_DATA/install-config.yaml"
    # if backup dir is not there, doing initial backup
    # otherwise, make sure all the files required are there
    if [ ! -d "$PPC_OCP_BACKUP" ]; then
        echo "Creating $PPC_OCP_BACKUP and backup files"
        mkdir  $PPC_OCP_BACKUP
        cp /var/named/zonefile.db $PPC_OCP_BACKUP/zonefile.db
        cp /var/named/reverse.db $PPC_OCP_BACKUP/reverse.db
        cp /etc/haproxy/haproxy.cfg $PPC_OCP_BACKUP/haproxy.cfg
        cp /etc/dhcp/dhcpd.conf $PPC_OCP_BACKUP/dhcpd.conf
        cp /etc/resolv.conf $PPC_OCP_BACKUP/resolv.conf
    fi
    file_must_exist "$PPC_OCP_BACKUP/zonefile.db"
    file_must_exist "$PPC_OCP_BACKUP/reverse.db"
    file_must_exist "$PPC_OCP_BACKUP/haproxy.cfg"
    # if the temp dir is not there, create one
    if [ ! -d "$PPC_OCP_TEMP_DIR" ]; then
        echo "Creating temp dir: $PPC_OCP_TEMP_DIR"
        mkdir $PPC_OCP_TEMP_DIR
    fi
}

#---------------------------------------------

command=$1
if [ -z "$1" ]; then
    command="start"
fi
if [[ $command == "--help" || $command == "-h" ]]; then
    usage
    exit 0
fi
if [[ $command != "start" && $command != "restart" && $command != "teardown" && $command != "bootstrap-wait" ]]; then
    echo "invalid command argument"
    usage
    exit 1
fi

precheck

# Manage debug option for openshft-install
if [[ $DEBUG == "true" || $DEBUG == "yes" || $DEBUG=1 ]]; then
    INSTALL_OPTS="--log-level debug"
fi

# reading data out of vars-static.yaml file

# read cluster id, DNS domain name and helper node IP
get_val_from_vars_file helper_ip ".helper.ipaddr"
get_val_from_vars_file cluster_id ".dns.clusterid"
get_val_from_vars_file dns_domain ".dns.domain"

# read vm creation related info
get_val_from_vars_file rhcos_image_name ".rhcos_image_name"
get_val_from_vars_file helper_subnet_id ".helper_subnet_id"

get_val_from_vars_file sys_type ".sys_type"
if [ -z "$sys_type" ] ; then
    echo "sys_type is not defined. set to s1022 as default"
    sys_type="s1022"
else
    echo "sys_type is: $sys_type"
fi

get_val_from_vars_file storage_tier ".storage_tier"
if [ -z "$storage_tier" ]; then
    echo "storage_tier is not defined, set to tier1 as default"
    storage_tier="tier1"
else
    echo "storage_tier is: $storage_tier"
fi

get_val_from_vars_file ssh_key_name ".ssh_key_name"
if [ -z "$ssh_key_name" ]; then
    echo "ssh_key_name is empty. No SSH key will be added during VM creation."
else
    echo "ssh_key_name is: $ssh_key_name"
fi

# read ibmcloud login related info
get_val_from_vars_file ibm_cloud_api_key ".ibm_cloud_api_key"
get_val_from_vars_file ibm_cloud_workspace_crn ".ibm_cloud_workspace_crn"

# Restore zonefile.db, reverse.db and haproxy.cfg file from backup
if [[ $command != "bootstrap-wait" ]]; then
   restore_changed_files "$PPC_OCP_BACKUP"
fi

need_retry="false"
for_control_plane="false"

if [ $command == "start" ]; then
    need_retry="true"
    start_install
    exit $?
fi

login_ibmcloud

if [[ $command == "restart" ]]; then
    need_retry="true"
    restart "true"
    exit $?
fi

if [[ $command == "teardown" ]]; then
    cleanup "true"
    exit $?
fi

if [ $command == "bootstrap-wait" ]; then
	need_retry="true"
	start_from_bootstrap
	exit $?
fi

#---------------------------------------------
