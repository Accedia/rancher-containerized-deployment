# ENTIRE SCRIPT VARIABLIZED

# Amend Values of variables below relevant to service and environment
# Below variables are passed through via the YAML pipeline
echo "rancherAccessKey: $rancherAccessKey"
echo "rancherSecretKey: $rancherSecretKey"
echo "rancherDeploymentApiUrl: $rancherDeploymentApiUrl"
echo "BuildDefinitionName: $BuildDefinitionName"
echo "BuildBuildNumber: $BuildBuildNumber"

## Function for Curl request to Rancher.
## Call like: curlwithcode $RANCHERAPIURL

curlwithcode() {
    code=0
    # Run curl in a separate command, capturing output of -w "%{http_code}" into statuscode
    # and sending the content to a file with -o >(cat >/tmp/curl_body)
    statuscode=$(curl -s -u "$rancherAccessKey:$rancherSecretKey" -w "%{http_code}" -k \
        -o >(cat >/tmp/curl_body) \
        "$@"
    ) || code="$?"

    body="$(cat /tmp/curl_body)"
    echo "{ \"statuscode\" : \"$statuscode\", \"exitcode\" : \"$code\", \"body\" : $body }"
}

RancherApiObjectFunction() {
    ## PrepareReplaceMent of values
    PrepareReplaceValueFunction
    ## Check values in Rancher for readiness Probes etc
    CheckReadinessFunction
    ## Deploy to RancherAPI
    DeployToRancherApiFunction
    ## Post Deployment Checks
    PostDeploymentFunction

    if [[ $(echo $OldOrNewRancherAPI) == "null" ]];
        then
            PostDeploymentChecksFunctionOldRancherObject
        else
            PostDeploymentChecksFunctionNewRancherObject
    fi
}

### Look for optimization for PostDeploymentChecksFunctionNewRancherObject/PostDeploymentChecksFunctionOldRancherObject

PostDeploymentChecksFunctionNewRancherObject() {
    if [[ $preDeploymentimageValue == $postDeploymentValue ]] && (( $postDeploymentUnavailableReplicas < 1 )) || [[ $postDeploymentValue == "" ]] || [[ $preDeploymentimageValue == "" ]];
        then
            echo "Not Updated or something went wrong" >&2
            exit
        else
            echo "Updated Successfully"
    fi
}

PostDeploymentChecksFunctionOldRancherObject() {
    if [[ $preDeploymentimageValue == $postDeploymentValue ]] && (( $postDeploymentUnavailableReplicas >= 1 )) || [[ $postDeploymentValue == "" ]] || [[ $preDeploymentimageValue == "" ]];
        then
            echo "Not Updated or something went wrong" >&2
            exit
        else
            echo "Updated Successfully"
    fi
}

PrepareReplaceValueFunction() {
    changeImageValues=$(echo $getCurrentValues | jq -r $containerPathVariable | sed 's/\:v.*/:v1.'$BuildBuildNumber'/')

    if [[ $(echo $OldOrNewRancherAPI) == "null" ]];
        then
            replaceImageVersionInPayload=$(echo $getCurrentValues | jq --arg changeImageValuesJQ $changeImageValues '.containers[].image |= $changeImageValuesJQ')
        else
            replaceImageVersionInPayload=$(echo $getCurrentValues | jq --arg changeImageValuesJQ $changeImageValues '.spec.template.spec.containers[].image |= $changeImageValuesJQ')
    fi

    FINALPAYLOAD=$(echo -n "$replaceImageVersionInPayload" |  jq .)
}

PostDeploymentFunction() {
    postDeploymentRequest=$(sleep $determineTimeForHealthCheckDelay && curlwithcode $rancherDeploymentApiUrl)

    if [[ $(echo $postDeploymentRequest | jq -r '.statuscode') != 200 ]];
        then
            echo "Post Deployment Request to Rancher failed with: $(echo $postDeploymentRequest| jq -r '.body')" >&2
            exit
        else
            echo "Post Deployment Request to Rancher successful"
    fi

    postDeploymentResult=$(echo -n $postDeploymentRequest | jq -r '.body')

    postDeploymentValue=$(echo -n $postDeploymentResult | jq -r $containerPathVariable)
    echo "postDeploymentValue: $postDeploymentValue"
    postDeploymentUnavailableReplicas=$(echo -n $postDeploymentResult | jq -r $postDeploymentUnavailableReplicasVariable)
    echo "postDeploymentUnavailableReplicas: $postDeploymentUnavailableReplicas"

    echo "PostDeploymentFunction finished"
}

DeployToRancherApiFunction() {
echo "FINALPAYLOAD inside DeployToRancherApiFunction: $FINALPAYLOAD"

# Update Rancher workload
deployChanges=$(curl -s -u "$rancherAccessKey:$rancherSecretKey" \
-i \
-X PUT \
-k \
-H 'Accept: application/json' \
-H 'Content-Type: application/json' \
-d "$FINALPAYLOAD" \
$rancherDeploymentApiUrl | grep HTTP/1.1)
echo "deployChanges: $deployChanges"
}

GetCurrentRancherApiObjects() {
    echo "Release.DefinitionName: $BuildDefinitionName"
    getCurrentValuesWithHttpCode=$(curlwithcode $rancherDeploymentApiUrl)
    echo "getCurrentValuesWithHttpCode: $getCurrentValuesWithHttpCode"
    # Get secret values
    #getCurrentSecretValuesWithHttpCode=$(curlwithcode $rancherSecretApiUrl)
    # Check httpcode returned and fail if not equal to 200
    if [[ $(echo $getCurrentValuesWithHttpCode | jq -r '.statuscode') != 200 ]]
        then
            echo "Pre Deployment Request to Rancher failed with: $(echo $getCurrentValuesWithHttpCode | jq -r '.body')" >&2
            exit
        else
            echo "Pre Deployment Request to Rancher successful"
    fi
    # Image Values body object
    getCurrentValues=$(echo $getCurrentValuesWithHttpCode | jq -r '.body')
    echo "getCurrentValues: $getCurrentValues"
    # Secret Values body object
    getSecretCurrentValues=$(echo $getCurrentSecretValuesWithHttpCode | jq -r '.body')
    echo "getSecretCurrentValues: $getSecretCurrentValues"
    echo "replaceSecretValueInPayload: $replaceSecretValueInPayload"
    OldOrNewRancherAPI=$(echo $getCurrentValues | jq -r '.metadata' 2> /dev/null)
    echo "OldOrNewRancherAPI: $OldOrNewRancherAPI"
}

CheckReadinessFunction() {
    preDeploymentimageValue=$(echo $getCurrentValues | jq -r $containerPathVariable)
    checkContainersDeployed=$(echo $getCurrentValues | jq -r $checkContainersDeployedVariable)
    checkReadinessProbePeriod=$(echo $getCurrentValues | jq -r $checkReadinessProbePeriodVariable)
    checkReadinessProbeInitialPeriod=$(echo $getCurrentValues | jq -r $checkReadinessProbeInitialPeriodVariable)
    checkReadinessProbeSuccessThreshold=$(echo $getCurrentValues | jq -r $checkReadinessProbeSuccessThresholdVariable)
    determineTimeForHealthCheckDelay=$(( (( $checkContainersDeployed * (( $checkReadinessProbePeriod * $checkReadinessProbeSuccessThreshold )) )) + $(( $checkReadinessProbeInitialPeriod * 2 )) ))
}

SetValues(){
    if [[ $(echo $OldOrNewRancherAPI) == "null" ]]
        then
            # Old RancherApi object
            ## Set values values to be used for version of Rancher json Object
            containerPathVariable='.containers[].image'
            checkContainersDeployedVariable='.deploymentStatus.availableReplicas'
            checkReadinessProbePeriodVariable='.containers[].readinessProbe.periodSeconds'
            checkReadinessProbeInitialPeriodVariable='.containers[].readinessProbe.initialDelaySeconds'
            checkReadinessProbeSuccessThresholdVariable='.containers[].readinessProbe.successThreshold'
            postDeploymentUnavailableReplicasVariable='.deploymentStatus.unavailableReplicas'
        else
            # New RancherApi object
            ## Set values values to be used for version of Rancher json Object
            containerPathVariable='.spec.template.spec.containers[].image'
            checkContainersDeployedVariable='.status.availableReplicas'
            checkReadinessProbePeriodVariable='.spec.template.spec.containers[].readinessProbe.periodSeconds'
            checkReadinessProbeInitialPeriodVariable='.spec.template.spec.containers[].readinessProbe.initialDelaySeconds'
            checkReadinessProbeSuccessThresholdVariable='.spec.template.spec.containers[].readinessProbe.successThreshold'
            postDeploymentUnavailableReplicasVariable='.status.readyReplicas'
    fi
}

GetCurrentRancherApiObjects
SetValues
RancherApiObjectFunction