#!/bin/bash -e

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
script_name=$(basename ${0##*/} .sh)
names_first=(`jq -r '.unicorn.first[]' ${script_dir}/names.json`)
names_middle=(`jq -r '.unicorn.middle[]' ${script_dir}/names.json`)
names_last=(`jq -r '.unicorn.last[]' ${script_dir}/names.json`)

zone_uri_list=(`gcloud compute zones list --uri`)
zone_name_list=("${zone_uri_list[@]##*/}")

livelogSecret=`pass Mozilla/TaskCluster/livelogSecret`
livelogcrt=`pass Mozilla/TaskCluster/livelogCert`
livelogkey=`pass Mozilla/TaskCluster/livelogKey`
pgpKey=`pass Mozilla/OpenCloudConfig/rootGpgKey`
relengapiToken=`pass Mozilla/OpenCloudConfig/tooltool-relengapi-tok`
occInstallersToken=`pass Mozilla/OpenCloudConfig/tooltool-occ-installers-tok`
provisionerId=releng-hardware
GITHUB_HEAD_SHA=`git rev-parse HEAD`
deploymentId=${GITHUB_HEAD_SHA:0:12}


if [[ $@ == *"--open-in-browser"* ]] && which xdg-open > /dev/null; then
  xdg-open "https://console.cloud.google.com/compute/instances?authuser=1&folder&organizationId&project=windows-workers&instancessize=50&duration=PT1H&pli=1&instancessort=zoneForFilter%252Cname"
fi

for manifest in $(ls ${script_dir}/../userdata/Manifest/*-gamma.json); do
  workerType=$(basename ${manifest##*/} .json)
  echo "$(tput dim)[${script_name} $(date --utc +"%F %T.%3NZ")]$(tput sgr0) worker type: $(tput bold)${workerType}$(tput sgr0)"

  accessToken=`pass Mozilla/TaskCluster/project/releng/generic-worker/${workerType}/production`

  instanceCpuCount=32
  machineTypes=(highcpu standard)
  echo "$(tput dim)[${script_name} $(date --utc +"%F %T.%3NZ")]$(tput sgr0) deployment id: $(tput bold)${deploymentId}$(tput sgr0)"

  # determine the number of instances to spawn by checking the pending count for the worker type
  pendingTaskCount=$(curl -s "https://queue.taskcluster.net/v1/pending/${provisionerId}/${workerType}" | jq '.pendingTasks')
  echo "$(tput dim)[${script_name} $(date --utc +"%F %T.%3NZ")]$(tput sgr0) pending tasks: $(tput bold)${pendingTaskCount}$(tput sgr0)"

  if [ ${pendingTaskCount} -gt 0 ]; then
    # spawn some instances
    for i in $(seq 1 ${pendingTaskCount}); do
      # pick a random machine type
      instanceType=n1-${machineTypes[$[$RANDOM % ${#machineTypes[@]}]]}-${instanceCpuCount}
      # pick a random zone that has region cpu quota (minus usage) higher than required instanceCpuCount
      zone_name=${zone_name_list[$[$RANDOM % ${#zone_name_list[@]}]]}
      region=${zone_name::-2}
      cpuQuota=$(gcloud compute regions describe ${region} --project windows-workers --format json | jq '.quotas[] | select(.metric == "CPUS").limit')
      cpuUsage=$(gcloud compute regions describe ${region} --project windows-workers --format json | jq '.quotas[] | select(.metric == "CPUS").usage')
      while (( (cpuQuota - cpuUsage) < instanceCpuCount )); do
        echo "$(tput dim)[${script_name} $(date --utc +"%F %T.%3NZ")] skipping region: ${region} (cpu quota: ${cpuQuota}, cpu usage: ${cpuUsage})$(tput sgr0)"
        zone_name=${zone_name_list[$[$RANDOM % ${#zone_name_list[@]}]]}
        region=${zone_name::-2}
        cpuQuota=$(gcloud compute regions describe ${region} --project windows-workers --format json | jq '.quotas[] | select(.metric == "CPUS").limit')
        cpuUsage=$(gcloud compute regions describe ${region} --project windows-workers --format json | jq '.quotas[] | select(.metric == "CPUS").usage')
      done
      # generate a random instance name which does not pre-exist
      existing_instance_uri_list=(`gcloud compute instances list --uri`)
      existing_instance_name_list=("${existing_instance_uri_list[@]##*/}")
      instance_name=${names_first[$[$RANDOM % ${#names_first[@]}]]}-${names_middle[$[$RANDOM % ${#names_middle[@]}]]}-${names_last[$[$RANDOM % ${#names_last[@]}]]}
      while [[ " ${existing_instance_name_list[@]} " =~ " ${instance_name} " ]]; do
        instance_name=${names_first[$[$RANDOM % ${#names_first[@]}]]}-${names_middle[$[$RANDOM % ${#names_middle[@]}]]}-${names_last[$[$RANDOM % ${#names_last[@]}]]}
      done

      echo "$(tput dim)[${script_name} $(date --utc +"%F %T.%3NZ")]$(tput sgr0) instance name: $(tput bold)${instance_name}$(tput sgr0)"
      echo "$(tput dim)[${script_name} $(date --utc +"%F %T.%3NZ")]$(tput sgr0) zone name: $(tput bold)${zone_name}$(tput sgr0)"
      echo "$(tput dim)[${script_name} $(date --utc +"%F %T.%3NZ")]$(tput sgr0) region: $(tput bold)${region}$(tput sgr0)"
      echo "$(tput dim)[${script_name} $(date --utc +"%F %T.%3NZ")]$(tput sgr0) instance type: $(tput bold)${instanceType}$(tput sgr0)"
      echo "$(tput dim)[${script_name} $(date --utc +"%F %T.%3NZ")]$(tput sgr0) worker group: $(tput bold)${region}$(tput sgr0)"

      gcloud compute instances create ${instance_name} \
        --image-project windows-cloud \
        --image-family windows-2012-r2 \
        --machine-type ${instanceType} \
        --boot-disk-size 50 \
        --boot-disk-type pd-ssd \
        --scopes storage-ro \
        --metadata "^;^windows-startup-script-url=gs://open-cloud-config/gcloud-startup.ps1;workerType=${workerType};sourceOrg=mozilla-releng;sourceRepo=OpenCloudConfig;sourceRevision=gamma;pgpKey=${pgpKey};livelogkey=${livelogkey};livelogcrt=${livelogcrt};relengapiToken=${relengapiToken};occInstallersToken=${occInstallersToken}" \
        --zone ${zone_name} \
        --preemptible
      publicIP=$(gcloud compute instances describe ${instance_name} --zone ${zone_name} --format json | jq -r '.networkInterfaces[0].accessConfigs[0].natIP')
      echo "$(tput dim)[${script_name} $(date --utc +"%F %T.%3NZ")]$(tput sgr0) public ip: $(tput bold)${publicIP}$(tput sgr0)"
      privateIP=$(gcloud compute instances describe ${instance_name} --zone ${zone_name} --format json | jq -r '.networkInterfaces[0].networkIP')
      echo "$(tput dim)[${script_name} $(date --utc +"%F %T.%3NZ")]$(tput sgr0) private ip: $(tput bold)${privateIP}$(tput sgr0)"
      instanceId=$(gcloud compute instances describe ${instance_name} --zone ${zone_name} --format json | jq -r '.id')
      echo "$(tput dim)[${script_name} $(date --utc +"%F %T.%3NZ")]$(tput sgr0) instance id: $(tput bold)${instanceId}$(tput sgr0)"
      gwConfig="`curl -s https://raw.githubusercontent.com/mozilla-releng/OpenCloudConfig/gamma/userdata/Manifest/${workerType}.json | jq --arg accessToken ${accessToken} --arg livelogSecret ${livelogSecret} --arg publicIP ${publicIP} --arg privateIP ${privateIP} --arg workerId ${instance_name} --arg provisionerId ${provisionerId} --arg region ${region} --arg deploymentId ${deploymentId} --arg availabilityZone ${zone_name} --arg instanceId ${instanceId} --arg instanceType ${instanceType} -c '.ProvisionerConfiguration.userData.genericWorker.config | .accessToken = $accessToken | .livelogSecret = $livelogSecret | .publicIP = $publicIP | .privateIP = $privateIP | .workerId = $workerId | .instanceId = $instanceId | .instanceType = $instanceType | .availabilityZone = $availabilityZone | .region = $region | .provisionerId = $provisionerId | .workerGroup = $region | .deploymentId = $deploymentId' | sed 's/\"/\\\"/g'`"
      gcloud compute instances add-metadata ${instance_name} --zone ${zone_name} --metadata "^;^gwConfig=${gwConfig}"
      gcloud beta compute disks create ${instance_name}-disk-1 --size 120 --type pd-ssd --physical-block-size 4096 --zone ${zone_name}
      gcloud compute instances attach-disk ${instance_name} --disk ${instance_name}-disk-1 --zone ${zone_name}
    done
  #else
    # delete instances that have never taken a task
    #for instance in $(curl -s "https://queue.taskcluster.net/v1/provisioners/${provisionerId}/worker-types/${workerType}/workers" | jq -r '.workers[] | select(.latestTask == null) | @base64'); do
    #  _jq() {
    #    echo ${instance} | base64 --decode | jq -r ${1}
    #  }
    #  zoneUrl=$(gcloud compute instances list --filter="name:$(_jq '.workerId') AND zone~$(_jq '.workerGroup')" --format=json | jq -r '.[0].zone')
    #  zone=${zoneUrl##*/}
    #  if [ -n "${zoneUrl}" ] && [ -n "${zone}" ] && [[ "${zone}" != "null" ]] && gcloud compute instances delete $(_jq '.workerId') --zone ${zone} --delete-disks all --quiet; then
    #    echo "$(tput dim)[${script_name} $(date --utc +"%F %T.%3NZ")]$(tput sgr0) deleted: $(tput bold)${zone}/$(_jq '.workerId')$(tput sgr0)"
    #  fi
    #done
  fi
done

# open the firewall to livelog traffic
# gcloud compute firewall-rules create livelog-direct --allow tcp:60023 --description "allows connections to livelog GET interface, running on taskcluster worker instances"