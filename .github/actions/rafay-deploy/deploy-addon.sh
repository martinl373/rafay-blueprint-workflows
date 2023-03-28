#!/bin/bash
##====================================================
## Script Initialization
##====================================================
## Configure the bash runtime
set -o nounset
set -o pipefail

## Setup temp workspace with exit trap cleanup
readonly workspace="$(mktemp -d -t addon.XXXXXX)"
function __delete_workspace() {
    [[ -d "${workspace}" ]] &&  rm -rf "${workspace}"
}
trap __delete_workspace EXIT


##====================================================
## Internal Variables
##====================================================
readonly log_line_format="[%s]: %s\n"
readonly log_time_format="%Y-%m-%dT%H:%M:%S%z"


##====================================================
## Internal Functions
##====================================================
function indent() {
	[[ $# -gt 0 ]] && echo "${@}" | indent && return

	local line
	while IFS= read -r line; do
		printf "  %s\n" "${line}"
	done
}

function log() {
	[[ $# -gt 0 ]] && echo "${@}" | log && return

	local line
	while IFS= read -r line; do
		printf "${log_line_format}" "$(date +${log_time_format})" "${line}"
	done
}

function log_indent() {
	indent "${@}" | log
}

##====================================================
## Main Script
##====================================================
addon_spec_file="${SPEC_FILE:-}"
addon_artifact_path="${ARTIFACT_PATH:-}"

addon_name="${NAME:-}"
addon_project="${PROJECT:-}"
addon_namespace="${NAMESPACE:-}"
addon_version="${VERSION:-}"

rafay_api_key="${RAFAY_API_KEY:-}"

## Check required input variables
if [[ -z "${addon_artifact_path}" && -z "${addon_spec_file}" ]]; then
    log "One of \$SPEC_FILE or \$ARTIFACT_PATH needs to be set"
    exit 1
fi
if [[ ! -z "${addon_artifact_path}" && ! -z "${addon_spec_file}" ]]; then
    log "Both \$SPEC_FILE or \$ARTIFACT_PATH can not be set at the same time"
    exit 1
fi

## Auto-generate a spec file from artifact path if none is specified
## otherwise check that the specified spec exists.
if [[ -z "${addon_spec_file}" ]]; then
    if [[ ! -e "${addon_artifact_path}" ]]; then
        log "Artifact path does not exist: ${addon_artifact_path}"
        exit 1
    fi

    log "Generating addon spec from input variables ..."

    ## Construct the YQ command string that will create the YAML. Add the artifact
    ## to right place depending on content type (Helm vs plain YAML)
    yq_string='.apiVersion = "infra.k8smgmt.io/v3" | .kind = "Addon"'
    if [[ -f "${addon_artifact_path}/Chart.yaml" || "${addon_artifact_path}" == *.tgz ]]; then
        yq_string+=' | .spec.artifact.type = "Helm"'
        yq_string+=' | .spec.artifact.artifact.chartPath.name = "file://./"'
    else
        yq_string+=' | .spec.artifact.type = "Yaml"'
        yq_string+=' | .spec.artifact.artifact.paths += [{"name" : "file://./"}]'
    fi

    ## Set the specfile location depending on artifact type. For file artifacts use the
    ## same parent folder, for directory type artifacts use that as root.
    if [[ -f "${addon_artifact_path}" ]]; then
        addon_spec_file=$(dirname "${${addon_artifact_path}}")/generated-addon
    else
        addon_spec_file="${addon_artifact_path}/generated-addon"
    fi
    
    ## Run YQ to generate the addon yaml
    yq -n "${yq_string}" > "${addon_spec_file}"
else
    if [[ ! -f "${addon_spec_file}" ]]; then
        log "Specified spec file does not exist: ${addon_spec_file}"
        exit 1
    fi
fi


## If artifact files are local do helm packing or YAML merging
if [[ -z $(yq '.spec.artifact.artifact.repository // ""' "${addon_spec_file}") ]]; then
    ## Get the chart path, if any, from the manifest
    chart_path=$(yq '.spec.artifact.artifact.chartPath.name // "" | capture("^(file:\/\/)?(?P<name>.*)$") | .name' "${addon_spec_file}")
    
    ## If the specified chart path exist and is a directory
    ## package the chart and update the manifest to point to the package
    if [[ -d "${chart_path}" ]]; then
        log "Packageing helm chart into tgz archive ..."
        helm package --dependency-update --destination "${workspace}" $(dirname "${addon_spec_file}")/"${chart_path}" | log_indent
        
        log "Updating spec file to use packaged chart ..."
        cp "${workspace}"/*.tgz $(dirname "${addon_spec_file}")/helm-chart.tgz
        yq -i '.spec.artifact.artifact.chartPath.name = "file://helm-chart.tgz"' "${addon_spec_file}"
    fi

    ## Get the yaml paths, if any, from the manifest
    yaml_paths=$(yq '.spec.artifact.artifact.paths[].name // ""' "${addon_spec_file}")

    ## Loop over all specified yaml files in the manifest
    ## (This is to paper over that the current client can only handle one file)
    if [[ ! -z "${yaml_paths}" ]]; then
        combined_yaml_file="${workspace}/combined.yaml"

        log "Merging all specified yaml manifests into one file ..."

        while IFS='' read item; do
            item_path="$(dirname "${addon_spec_file}")/${item#file://}"

            ## If item is a regular file add it to the combined file
            if [[ -f "${item_path}" ]]; then
                log_indent "+ ${item_path}"
                echo -e "---\n## Source: ./${item#file://}" >> "${combined_yaml_file}"
                cat "${item_path}" >> "${combined_yaml_file}"
            
            ## If item is a directory, scan it and add all yaml files
            elif [[ -d "${item_path}" ]]; then
                while IFS='' read filespec; do
                    log_indent "+ ${item_path}"
                    echo -e "---\n## Source: ${filespec}" >> "${combined_yaml_file}"
                    cat "${item_path}/${filespec}" >> "${combined_yaml_file}"
                done < <(cd "${item_path}/"; find . -type f "(" -iname "*.yaml" -or -iname "*.yml" ")" | sort)
            
            ## Fail with error if item does not exist
            else
                log "Artifact file from spec does not exist: ${item_path}"
                exit 1
            fi
        done <<< "${yaml_paths}"

        ## Copy in the combined file and add it to the spec file
        log "Updating spec file to use merged yaml bundle ..."
        cp "${combined_yaml_file}" $(dirname "${addon_spec_file}")/
        yq -i '.spec.artifact.artifact.paths = [{"name" : "file://combined.yaml"}]' "${addon_spec_file}"
    fi
fi

## Update addon parameters if overrides are specified
log "Updating spec fields from input ..."
if [[ ! -z "${addon_name:-}" ]]; then
    log_indent '.metadata.name = "'${addon_name}'"'
    yq -i '.metadata.name = "'${addon_name}'"' "${addon_spec_file}"
fi
[[ ! -z "${addon_project:-}" ]]; then
    log_indent '.metadata.project = "'${addon_project}'"'
    yq -i '.metadata.project = "'${addon_project}'"' "${addon_spec_file}"
fi
[[ ! -z "${addon_namespace:-}" ]]; then
    log_indent '.spec.namespace = "'${addon_namespace}'"'
    yq -i '.spec.namespace = "'${addon_namespace}'"' "${addon_spec_file}"
fi
[[ ! -z "${addon_version:-}" ]]; then
    log_indent '.spec.version = "'${addon_version}'"'
    yq -i '.spec.version = "'${addon_version}'"' "${addon_spec_file}"
fi

## Run rctl to make the deploy API call
log "Deploying addon ..."
RCTL_PROJECT="defaultproject" \
RCTL_API_KEY="${rafay_api_key}" \
RCTL_API_SECRET="${rafay_api_key}" \
rctl create addon version --v3 -f "${addon_spec_file}" | log_indent
log "all done."