#!/bin/bash

# Copyright (c) 2015, Isaac I. Y. Saito
# Copyright (c) 2017, Mathias Luedtke
# All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
## Greatly inspired by JSK travis https://github.com/jsk-ros-pkg/jsk_travis

# source_tests.sh script runs integration tests for the target ROS packages.
# It is dependent on environment variables that need to be exported in advance
# (As of version 0.4.4 most of them are defined in env.sh).

ici_require_run_in_docker # this script must be run in docker

#Define some verbose env vars
#verbose build
if [ "$VERBOSE_OUTPUT" ] && [ "$VERBOSE_OUTPUT" == true ]; then
    OPT_VI="-vi"
else
    OPT_VI=""
fi
#verbose run tests
if [ "$VERBOSE_TESTS" == false ]; then
    OPT_RUN_V=""
else
    OPT_RUN_V="-v"
fi

ici_time_start init_ici_environment
# Define more env vars
BUILDER=catkin
ROSWS=wstool

ici_time_end  # init_ici_environment

function catkin {
  local path
  path=$(which catkin) || error "catkin not available. Make sure python-catkin-tools is installed. See also https://github.com/ros-industrial/industrial_ci/issues/216"
  local cmd=$1
  shift
  "$path" "$cmd" -w "$CATKIN_WORKSPACE" "$@"
}

ici_time_start setup_apt

sudo apt-get update -qq

# If more DEBs needed during preparation, define ADDITIONAL_DEBS variable where you list the name of DEB(S, delimitted by whitespace)
if [ "$ADDITIONAL_DEBS" ]; then
    sudo apt-get install -qq -y $ADDITIONAL_DEBS || error "One or more additional deb installation is failed. Exiting."
fi
source /opt/ros/$ROS_DISTRO/setup.bash

ici_time_end  # setup_apt

if [ "$CCACHE_DIR" ]; then
    ici_time_start setup_ccache
    sudo apt-get install -qq -y ccache || error "Could not install ccache. Exiting."
    export PATH="/usr/lib/ccache:$PATH"
    ici_time_end  # setup_ccache
fi

ici_time_section "setup_rosdep" ici_setup_rosdep

ici_time_start setup_workspace

## BEGIN: travis' install: # Use this to install any prerequisites or dependencies necessary to run your build ##
# Create workspace
export WORKSPACE=~/catkin_ws
export CATKIN_WORKSPACE="$WORKSPACE"

ici_create_workspace "$WORKSPACE"
ici_workspace_fetch_remote "$WORKSPACE" "$UPSTREAM_WORKSPACE"

ici_link_into_workspace "$WORKSPACE" "$TARGET_REPO_PATH"

if [ "${USE_MOCKUP// }" != "" ]; then
    if [ ! -d "$TARGET_REPO_PATH/$USE_MOCKUP" ]; then
        error "mockup directory '$USE_MOCKUP' does not exist"
    fi
    ici_link_into_workspace "$WORKSPACE" "$TARGET_REPO_PATH/$USE_MOCKUP"
fi

catkin config --install
if [ -n "$CATKIN_CONFIG" ]; then eval catkin config $CATKIN_CONFIG; fi

ici_time_end  # setup_rosws


# execute BEFORE_SCRIPT in repository, exit on errors
if [ "${BEFORE_SCRIPT// }" != "" ]; then
  ici_time_start before_script

  bash -e -c "cd $TARGET_REPO_PATH; ${BEFORE_SCRIPT}"

  ici_time_end  # before_script
fi

ici_time_section "rosdep_install" ici_install_workspace_dependencies "$WORKSPACE"

if [ "$CATKIN_LINT" == "true" ] || [ "$CATKIN_LINT" == "pedantic" ]; then
    ici_time_start catkin_lint
    sudo pip install catkin-lint
    if [ "$CATKIN_LINT" == "pedantic" ]; then
    	CATKIN_LINT_ARGS="$CATKIN_LINT_ARGS --strict -W2"
    fi
    catkin_lint --explain $CATKIN_LINT_ARGS $TARGET_REPO_PATH && echo "catkin_lint passed." || error "catkin_lint failed by either/both errors and/or warnings"
    ici_time_end  # catkin_lint
fi

ici_time_start catkin_build

# for catkin
if [ "${TARGET_PKGS// }" == "" ]; then export TARGET_PKGS=`catkin_topological_order ${TARGET_REPO_PATH} --only-names`; fi
# fall-back to all workspace packages if target repo does not contain any packages (#232)
if [ "${TARGET_PKGS// }" == "" ]; then export TARGET_PKGS=`catkin_topological_order $CATKIN_WORKSPACE/src --only-names`; fi
if [ "${PKGS_DOWNSTREAM// }" == "" ]; then export PKGS_DOWNSTREAM=$( [ "${BUILD_PKGS_WHITELIST// }" == "" ] && echo "$TARGET_PKGS" || echo "$BUILD_PKGS_WHITELIST"); fi
if [ "$BUILDER" == catkin ]; then catkin build $OPT_VI --summarize  --no-status $BUILD_PKGS_WHITELIST $CATKIN_PARALLEL_JOBS --make-args $ROS_PARALLEL_JOBS            ; fi

ici_time_end  # catkin_build

if [ "$NOT_TEST_BUILD" != "true" ]; then
    ici_time_start catkin_build_downstream_pkgs
    if [ "$BUILDER" == catkin ]; then
        catkin build $OPT_VI --summarize  --no-status $PKGS_DOWNSTREAM $CATKIN_PARALLEL_JOBS --make-args $ROS_PARALLEL_JOBS
    fi
    ici_time_end  # catkin_build_downstream_pkgs

    ici_time_start catkin_build_tests
    if [ "$BUILDER" == catkin ]; then
        catkin build --no-deps --catkin-make-args tests -- $OPT_VI --summarize  --no-status $PKGS_DOWNSTREAM $CATKIN_PARALLEL_JOBS --make-args $ROS_PARALLEL_JOBS --
    fi
    ici_time_end  # catkin_build_tests

    ici_time_start catkin_run_tests
    if [ "$BUILDER" == catkin ]; then
        catkin build --no-deps --catkin-make-args run_tests -- $OPT_RUN_V --no-status $PKGS_DOWNSTREAM $CATKIN_PARALLEL_TEST_JOBS --make-args $ROS_PARALLEL_TEST_JOBS --
        if [ "${ROS_DISTRO}" == "hydro" ]; then
            PATH=/usr/local/bin:$PATH  # for installed catkin_test_results
            PYTHONPATH=/usr/local/lib/python2.7/dist-packages:$PYTHONPATH

            if [ "${ROS_LOG_DIR// }" == "" ]; then export ROS_LOG_DIR=~/.ros/test_results; fi # http://wiki.ros.org/ROS/EnvironmentVariables#ROS_LOG_DIR
            if [ "$BUILDER" == catkin -a -e $ROS_LOG_DIR ]; then catkin_test_results --all $ROS_LOG_DIR || error; fi
            if [ "$BUILDER" == catkin -a -e $CATKIN_WORKSPACE/build/ ]; then catkin_test_results --all $CATKIN_WORKSPACE/build/ || error; fi
            if [ "$BUILDER" == catkin -a -e ~/.ros/test_results/ ]; then catkin_test_results --all ~/.ros/test_results/ || error; fi
        else
            catkin_test_results --verbose $CATKIN_WORKSPACE || error
        fi
    fi
    ici_time_end  # catkin_run_tests
fi

if [ "$NOT_TEST_INSTALL" != "true" ]; then

    ici_time_start catkin_install_run_tests

    EXIT_STATUS=0
    # Test if the unit tests in the packages in the downstream repo pass.
    if [ "$BUILDER" == catkin ]; then
      for pkg in $PKGS_DOWNSTREAM; do
        if [ ! -d "$CATKIN_WORKSPACE/install/share/$pkg" ]; then continue; fi # skip meta-packages

        echo "[$pkg] Started testing..."
        rostest_files=$(find "$CATKIN_WORKSPACE/install/share/$pkg" -iname '*.test')
        echo "[$pkg] Found $(echo $rostest_files | wc -w) tests."
        for test_file in $rostest_files; do
          echo "[$pkg] Testing $test_file"
          $CATKIN_WORKSPACE/install/env.sh rostest $test_file || EXIT_STATUS=$?
          if [ $EXIT_STATUS != 0 ]; then
            echo -e "[$pkg] Testing again the failed test: $test_file.\e[31m>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>\e[0m"
            $CATKIN_WORKSPACE/install/env.sh rostest --text $test_file
            echo -e "[$pkg] Testing again the failed test: $test_file.\e[31m<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<\e[0m"
          fi
        done
      done
      [ $EXIT_STATUS -eq 0 ] || error  # unless all tests pass, raise error
    fi

    ici_time_end  # catkin_install_run_tests

fi
