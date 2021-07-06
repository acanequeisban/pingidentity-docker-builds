#!/usr/bin/env sh
#
# Ping Identity DevOps - CI scripts
#
# This script creates and pushes multi-arch image manifests to registries based on the
# registries listed in the product's versions.json file
#
test "${VERBOSE}" = "true" && set -x

# Usage printing function
usage() {
    cat << END_USAGE
Usage: ${0} {options}
    where {options} include:

    -p, --product
        The name of the product for which to build a manifest
    --dry-run
        does everything except actually call the docker command and prints it instead
    --help
        Display general usage information
END_USAGE
    test -n "${*}" && echo "${*}"
    exit 99
}

# Executes the command passed, and fails if return code ne 0
exec_cmd_or_fail() {
    eval "${dry_run} ${*}"
    result_code=${?}
    test "${result_code}" -ne 0 && echo_red "The following command resulted in an error: ${*}" && exit "${result_code}"
}

create_manifest_and_push() {
    target_manifest_name="${1}"
    # Word-split is expected behavior for $images_list. Disable shellcheck.
    # shellcheck disable=SC2086
    exec_cmd_or_fail docker manifest create "${target_registry_url}/${product_to_deploy}:${target_manifest_name}" ${images_list}
    exec_cmd_or_fail docker manifest push --purge "${target_registry_url}/${product_to_deploy}:${target_manifest_name}"
    echo "Successfully created and pushed manifest: ${target_registry_url}/${product_to_deploy}:${target_manifest_name}"
}

while test -n "${1}"; do
    case "${1}" in
        -p | --product)
            shift
            test -z "${1}" && usage "You must provide a product to build"
            product_to_deploy="${1}"
            ;;
        --dry-run)
            dry_run="echo"
            ;;
        --help)
            usage
            ;;
        *)
            usage "Unrecognized option"
            ;;
    esac
    shift
done

test -z "${product_to_deploy}" &&
    usage "Specifying a product to deploy is required"

if test -z "${CI_COMMIT_REF_NAME}"; then
    CI_PROJECT_DIR="$(
        cd "$(dirname "${0}")/.." || exit 97
        pwd
    )"
    test -z "${CI_PROJECT_DIR}" && echo "Invalid call to dirname ${0}" && exit 97
fi
CI_SCRIPTS_DIR="${CI_PROJECT_DIR:-.}/ci_scripts"
# shellcheck source=./ci_tools.lib.sh
. "${CI_SCRIPTS_DIR}/ci_tools.lib.sh"

#
# Determine whether the commit is associated with a sprint tag
# a print tag ends with 4 digits, YYMM
for tag in $(git tag --points-at "${GIT_REV_LONG}"); do
    if test -z "${tag##2[0-9][0-9][0-9]*}"; then
        sprint="${tag}"
        break
    fi
done

#Define docker config file locations based on different image registry providers
docker_config_hub_dir="/root/.docker-hub"
# docker_config_artifactory_dir="/root/.docker-artifactory"

versions_to_deploy=$(_getAllVersionsToDeployForProduct "${product_to_deploy}")
latest_version=$(_getLatestVersionForProduct "${product_to_deploy}")

banner "Running deploy_manifests_to_registry for Product: ${product_to_deploy}"
for version in ${versions_to_deploy}; do
    shims_to_deploy=$(_getShimsToDeployForProductVersion "${product_to_deploy}" "${version}")
    default_shim=$(_getDefaultShimForProductVersion "${product_to_deploy}" "${version}")
    for shim in ${shims_to_deploy}; do
        shim_long_tag=$(_getLongTag "${shim}")
        jvms_to_deploy=$(_getJVMsToDeployForProductVersionShim "${product_to_deploy}" "${version}" "${shim}")
        default_jvm=$(_getPreferredJVMForProductVersionShim "${product_to_deploy}" "${version}" "${shim}")
        for jvm in ${jvms_to_deploy}; do
            registry_list=$(_getTargetRegistriesForProductVersionShimJVM "${product_to_deploy}" "${version}" "${shim}" "${jvm}")
            for target_registry in ${registry_list}; do
                target_registry=$(toLower "${target_registry}")
                case "${target_registry}" in
                    "artifactory")
                        # TODO Artifactory is using v1 manifests. Update this to use manifests in Artifactory
                        echo_yellow "Registry ${target_registry} is not implemented in deploy_manifests.sh"
                        # target_registry_url="${ARTIFACTORY_REGISTRY}"
                        # docker_config="${docker_config_artifactory_dir}"
                        continue
                        ;;
                    "dockerhub")
                        target_registry_url="${DOCKER_HUB_REGISTRY}"
                        docker_config="${docker_config_hub_dir}"
                        ;;
                    *)
                        echo_red "Registry ${target_registry} is not implemented in deploy_manifests.sh" && exit 1
                        ;;
                esac

                # Create a list of images that can be combined into a
                # multi-arch manifest for the provided product, shim, jvm, and version
                images_list=""
                banner "Verifying Images From ${target_registry} for: ${product_to_deploy} ${shim} ${jvm} ${version}"
                for arch in $(_getAllArchsForJVM "${jvm}"); do
                    current_image="${target_registry_url}/${product_to_deploy}:${version}-${shim_long_tag}-${jvm}-${arch}-edge"
                    #Verify the image exists on the target_registry
                    exec_cmd_or_fail docker --config "${docker_config}" manifest inspect "${current_image}"
                    images_list="${images_list:+${images_list} }${current_image}"
                    echo "Image verified: ${current_image}"
                done # iterating over architectures

                #This builds pushes manifests to the target registry that contain the images in $images_list
                banner "Creating Multi-Arch Manifests in ${target_registry} for: ${product_to_deploy} ${shim} ${jvm} ${version}"
                if test -n "${sprint}"; then
                    create_manifest_and_push "${version}-${shim_long_tag}-${jvm}-latest"
                    create_manifest_and_push "${sprint}-${version}-${shim_long_tag}-${jvm}"
                    if test "${shim}" = "${default_shim}" && test "${jvm}" = "${default_jvm}"; then
                        create_manifest_and_push "${version}-latest"
                        create_manifest_and_push "${sprint}-${version}"
                        if test "${version}" = "${latest_version}"; then
                            create_manifest_and_push "latest"
                            create_manifest_and_push "${sprint}"
                        fi
                    fi
                fi
                if test "${shim}" = "${default_shim}" && test "${jvm}" = "${default_jvm}"; then
                    create_manifest_and_push "${version}-edge"
                    if test "${version}" = "${latest_version}"; then
                        create_manifest_and_push "edge"
                    fi
                fi
                create_manifest_and_push "${version}-${shim_long_tag}-${jvm}-edge"

                # Delete images of type ${version}-${shim_long_tag}-${jvm}-${arch}-edge from target registry
                # These images are no longer needed, as they should be accessible in multi-arch manifest images formed above
                banner "Deleting Non-Multi-Arch Images in ${target_registry} for: ${product_to_deploy} ${shim} ${jvm} ${version}"
                case "${target_registry}" in
                    "dockerhub")
                        # Get Dockerhub Auth Token
                        http_response_code=$(curl --silent --request "POST" --write-out '%{http_code}' --output "/tmp/dockerhub.api.out" --header "Content-Type: application/json" --data '{"username": "'"${DOCKER_USERNAME}"'", "password": "'"${DOCKER_PASSWORD}"'"}' "https://hub.docker.com/v2/users/login/")
                        if test "${http_response_code}" -eq 200; then
                            dockerhub_auth_token=$(jq -r .token "/tmp/dockerhub.api.out")
                            echo "Successfully Retrieved Login Auth Token from DockerHub"
                        else
                            echo_red "${http_response_code}: Unable to login to dockerhub for tag deletion" && exit 1
                        fi

                        # Loop through Architectures and delete images used to build manifests.
                        for arch in $(_getAllArchsForJVM "${jvm}"); do
                            http_response_code=$(curl --silent --request "DELETE" --write-out '%{http_code}' --output "/dev/null" --header "Authorization: JWT ${dockerhub_auth_token}" "https://hub.docker.com/v2/repositories/pingidentity/${product_to_deploy}/tags/${version}-${shim_long_tag}-${jvm}-${arch}-edge/")
                            if test "${http_response_code}" -eq 204; then
                                echo "Successfully deleted image tag: ${version}-${shim_long_tag}-${jvm}-${arch}-edge"
                            else
                                echo_red "${http_response_code}: Unable to delete image tag: ${version}-${shim_long_tag}-${jvm}-${arch}-edge" && exit 1
                            fi
                        done # iterating over architectures

                        # Log out Dockerhub Auth Token
                        http_response_code=$(curl --silent --request "POST" --write-out '%{http_code}' --output "/dev/null" --header "Authorization: JWT ${dockerhub_auth_token}" "https://hub.docker.com/v2/logout/")
                        if test "${http_response_code}" -ne 200; then
                            echo_red "${http_response_code}: Unable to logout from dockerhub after tag deletion" && exit 1
                        else
                            echo "Successfully Logged Out Auth Token from DockerHub"
                        fi
                        ;;
                    *)
                        echo_yellow "Tag Deletion for Registry ${target_registry} is not implemented in deploy_manifests_to_registry.sh"
                        ;;
                esac
            done # iterating over target registries
        done     # iterating over JVMS
    done         # iterating over shims
done             # iterating over versions
exit 0
