# Extra automation scripts for OpenShift on IBM Power Private Infrastructure

This repository consists of additional automation, scripts, playbooks, etc. for supporting OCP on IBM PowerVS Private

## Create a Red Hat OpenShift Cluster on PowerVS Private Infrastructure

This script is meant to be used from a Helper Node created using the OCP
Helper Node Playbooks found at https://github.com/redhat-cop/ocp4-helpernode.

Instructions for Getting Started can be found as part of the Power Virtual
Server Learning Series here: https://developer.ibm.com/series/deploy-ocp-cloud-paks-power-virtual-server.
Be sure to locate the specific Learning Path for Private Infrastructure.

To summarize the official OpenShift documentation, you will need to have:
1. each of your control plane and worker nodes in DNS before they boot so
that they can be found by name. Both forward and reverse lookups are required.
1. A way to assign IPs to your VMs (we're using DHCP as PowerVS assigns static IPs
using cloud-init)
1. [Recommended] A load-balancer for the cluster API nodes. 

The helper node playbooks will create all of those things. The script in this directory
will create the VMs needed for your cluster, and modify the running configuration on
the helper node as resources become available.

### Pre-Requisites 
Make sure you have installed the ibmcloud cli and the ibmcloud power-iaas plugin
on the helper node.

1.    Install the resolvectl cli 

        ```ocp-helper#  dnf install systemd-resolved ```

1.   Create an IBM Cloud API Key 

        If you have not already, create an API Key: 

        ```ocp-helper#  ibmcloud iam api-key-create NAME ```
        ```ocp-helper#  export IBMCLOUD_API_KEY=<your_key> ```
            
        This key should be kept secret.  

1. Import the OS image for the VMs into your workspace 

    First find the name of the image. These images are stored in regional COS buckets in IBM Cloud. Choose the image in the bucket closest to your workspace region for the fastest download.  
    
    The following command will show you all images in all regions:  

    ```ocp-helper#  openshift-install coreos print-stream-json | grep '\.ova.gz[^.]' ```

    The bucket name for each region begins with `rhcos-powervs-images-`.   

    For example, in the br-sao (Sao Paulo) region: "https://s3.br-sao.cloud-object-storage.appdomain.cloud/rhcos-powervs-images-br-sao/rhcos-418-94-202501221327-0-ppc64le-powervs.ova.gz", the bucket name is rhcos-powervs-images-br-sao.  

    Use the following command to import an image into your workspace:  

    Note: You can use an SSO method or specify an API Key, or if you set IBMCLOUD_API_KEY above the CLI will login using that API Key. 

    ```ocp-helper# ibmcloud login --no-region ```
    ```ocp-helper# ibmcloud pi ws target <workspace_crn> ```
    ```ocp-helper# ibmcloud pi img im <rhcos_image_name_after_import> --bucket-access=public --region <cos_region> --bucket <cos_bucket_name> --image-file-name <ova_gz_image_file_name> ```

    This will take from 5-10 minutes. You an check the progress of the import operation by using the ibmcloud pi job command. The job ID was output from the image import command you just executed. 

    ```ocp-helper# ibmcloud pi job get b4f873df-eff8-4cbf-bbaf-ade4ecff87b9```
    ```Getting job b4f873df-eff8-4cbf-bbaf-ade4ecff87b9 under account Test Account as user me@us.ibm.com... ```
    ```Job ID b4f873df-eff8-4cbf-bbaf-ade4ecff87b9 Creation Timestamp 2025-06-16T15:52:39.224Z Operation ID rhcos-4_18-94 Operation Target image Operation Action epaImageImport State running Progress imageDownload Message image download is in progress ```

 
1. Create the OCP Install Configuration 

1. Create an ocp directory and set an environment variable: 

    ```
    ocp-helper# mkdir –p ocp/data 
    ocp-helper# export OCP_DIR=`pwd`/ocp 
    ```

1. Link the ocp4-helpernode/vars-ppc64le.yaml file into the $OCP_DIR/data directory. 
    Note: Your file location may be different. 

    ```
    ocp-helper# ln –s /full_path_to/ocp4-helpernode/vars-ppc64le.yaml ocp/data/vars.yaml

1. Update the $OCP_DIR/data/vars.yaml file by adding the following: 
    Note: The script checks for blank values, but does not validate values. 

    ```
    #The api key you created for your account. 
    ibm_cloud_api_key: "" 
    # Your workspace CRN. In the ibm cloud GUI, when you click on your workspace, 
    # the CRN will show in the window pop-up. 
    ibm_cloud_workspace_crn: "" 
    # Helper subnet is the subnet used by the helper node.  
    helper_subnet_name: "" 
    # The system type for your VMs (include bootstrap, masters, workers). 
    # Default value is s1022. 
    sys_type: "" 
    # The storage tier used to create VMs, the default value is tier1. 
    storage_tier: "" 
    # You need to import the RHCOS image to your workspace first and use 
    # the "ibmcloud pi img ls" command to get the image name. 
    rhcos_image_name: "" 
    ```
1. Create an install-config.yaml 

    1. Copy the sample install-config.yaml from https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html/installing_on_any_platform/installing-platform-agnostic#installation-initializing-manual_installing-platform-agnostic 
    1. Be sure you are viewing the documentation for the OCP version you are installing. The 4.x number in the middle of the URL indicates the version.  
    1. Save and edit the file from outside of the ocp directory you created earlier. The installer will delete this file when it runs. If you want to re-use it or need to re-run in case of error, you will want to have it backed up.  
    1. Modify the sample install-config.yaml file as follows: 
        - Change the baseDomain to the value you used in your helper node configuration.  
        - Set the number of worker replicas [optional]. 
        - Under metadata, set a name for your cluster [optional]. 
        - Set the CIDR of the clusterNetwork to match the PowerVS subnet you created in your workspace. 
        - Follow the open-shift install documentation linked in this section for instructions on how to retrieve your pull secret obtained from the OpenShift Cluster Manager console.  
        - It is recommended that you use the ssh key generated by the previous Ansible Playbook run on the ocp-helper node (found in the /root/.ssh directory). 
    1. When you have finished editing this file, make a COPY of it in the /data directory. 
        ``` 
        ocp-helper# cp install-config.yaml $OCP_DIR/data/. 
       ```
1. Create the $OCP_DIR/scripts directory and add it to the PATH environment variable. 
1. Download and run ocp_install_ppc script 
1. Download ocp_install_ppc.sh from this directory and copy it to the $OCP_DIR/scripts directory. 
1. Change the ocp_install.sh file permissions to make it executable: 
    ```
    ocp-helper# chmod +x ocp_install_ppc.sh 
    ```
1. Execute the script to create your cluster. 
    ```
    ocp-helper# $OCP_DIR/scripts/ocp_install_ppc.sh start 
    ``` 
    Note the start action is the default one. It can be omitted. 
    If you encounter errors, see the usage information by providing the -h flag. 
   
### Further information

1. Teardown the current installation 
    IBM Cloud resources created by previous script execution can be delete with: 
    ```
    ocp-helper# $OCP_DIR/scripts/ocp_install.sh teardown
    ```
1. Retry the installation
This will destroy resources and recreate from scratch:
    ```
    ocp-helper# $OCP_DIR/scripts/ocp_install.sh restart 
    ```

###  Configuring the image registry storage for your cluster

By default, the installation configures local storage on one of the VMs for your image registry. Most likely you will want to configure storage that is external to your nodes, in case of node failure. Read the following documentation to learn more about configuring storage for your registry:  

https://docs.openshift.com/container-platform/<your_openshift_version>/registry/configuring_registry_storage/configuring-registry-storage-baremetal.html 

After configuring the image registry storage, you also need to change the script to add in the following command call before creating the worker nodes: 

oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Managed"}}' 

### Troubleshooting

- For ibmcloud pi command failures, please make sure the command can run outside the ocp_install.sh script.  
- For other errors, try to do the cleanup and restart the install process. 
