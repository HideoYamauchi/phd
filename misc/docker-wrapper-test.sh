#!/bin/bash

container="hatest"
baseimage="centos:centos7"
image="centos:dock-wrapper-test"
curtest="unknown"
rpmdir="$1"

clear_vars()
{
	local prefix=OCF
	local tmp

	for tmp in $(printenv | grep -e "^${prefix}_*" | awk -F= '{print $1}'); do
		unset $tmp
	done

	return 0
}

default_vars()
{
	export OCF_ROOT=/usr/lib/ocf
	export OCF_RESKEY_CRM_meta_provider="heartbeat" OCF_RESKEY_CRM_meta_class="ocf" OCF_RESKEY_CRM_meta_type="Dummy" OCF_RESKEY_CRM_meta_isolation_instance="$container"
	export OCF_RESOURCE_INSTANCE="test" OCF_RESKEY_pcmk_docker_image="$image"
}

cleanup()
{
	rm -rf rpms
	docker kill $container > /dev/null 2>&1
	docker rm $container > /dev/null 2>&1
}

build_image()
{
	from="$baseimage"
	to="$image"

	cleanup
	docker rmi $to
	rm -rf Dockerfile

	docker pull "$from"
	if [ $? -ne 0 ]; then
		echo "ERROR: failed to pull docker image $from"
		exit 1
	fi

	# Create Dockerfile for image creation.
	echo "FROM $from" > Dockerfile
	rm -rf rpms
	mkdir rpms
	if [ -n "$rpmdir" ]; then
		echo "ADD /rpms /root/" >> Dockerfile
		echo "RUN yum install -y /root/*.rpm" >> Dockerfile
		cp $rpmdir/* rpms/
	else
		echo "RUN yum install -y resource-agents pacemaker-remote pacemaker" >> Dockerfile
	fi

	docker build -t "$to" .
	if [ $? -ne 0 ]; then
		echo "ERROR: failed to generate docker image"
		exit 1
	fi

	# cleanup
	rm -rf Dockerfile
}

docker_exec()
{
	local cmd=$1
	local expected_rc=$2
	local rc

	echo "---- Executing $cmd of test $curtest ----"
	/usr/lib/ocf/resource.d/isolation/docker-wrapper $cmd
	rc=$?	

	if [ "$cmd" = "start" ] && [ $rc -eq 0 ]; then
		local portcheck=0
		docker port $container 3121 > /dev/null 2>&1
		portcheck=$?
		if [ "$portcheck" -ne "0" ] && [ -n "$OCF_RESKEY_pcmk_docker_privileged" ]; then
			echo "FAILED: test $curtest: privileged enabled but port 3121 is not mapped."
			exit 1
		elif [ "$portcheck" -eq "0" ] && [ -z "$OCF_RESKEY_pcmk_docker_privileged" ]; then
			echo "FAILED: test $curtest: privileged disabled but port 3121 is mapped."
			exit 1
		fi
	fi

	if [ $rc -ne $expected_rc ]; then
		echo "FAILED: test $curtest: expected exit code $expected_rc, but got $rc"
		exit 1
	fi
	return 0

}

test_simple()
{
	default_vars
	curtest="simple"

	docker_exec "stop" "0"
	docker_exec "monitor" "7"
	docker_exec "start" "0"
	docker_exec "monitor" "0"
	docker_exec "start" "0"
	docker_exec "monitor" "0"
	docker_exec "stop" "0"
	docker_exec "stop" "0"
	docker_exec "monitor" "7"
}

test_failure_detection()
{
	default_vars
	curtest="failure_detection"

	docker_exec "monitor" "7"
	docker_exec "start" "0"
	docker_exec "monitor" "0"

	docker kill "$container"
	docker_exec "monitor" "7"
	docker_exec "stop" "0"
	docker_exec "start" "0"
	docker_exec "stop" "0"
}


test_failure_detection_pid1()
{
	default_vars
	curtest="failure_detection_pid1"

	docker_exec "monitor" "7"
	docker_exec "start" "0"
	docker_exec "monitor" "0"

	# you can kill container process from host actually. kind of interesting
	killall -9 pacemaker_remoted
	killall -9 lrmd
	docker_exec "monitor" "7"
	docker_exec "stop" "0"
}

test_failure_invalid_image()
{
	default_vars
	curtest="failure_invalid_image"

	export OCF_RESKEY_pcmk_docker_image="manbearpig"

	docker_exec "stop" "0"
	docker_exec "monitor" "7"
	docker_exec "start" "6"
}

#TODO verify more complex args make it to isolated resource correctly
test_arg_passing()
{
	default_vars
	curtest="arg_passing"

	rm -rf /usr/lib/ocf/resource.d/wraptest
	mkdir /usr/lib/ocf/resource.d/wraptest
	echo "#!/bin/bash" > /usr/lib/ocf/resource.d/wraptest/WrapDummy
	echo "printenv > /usr/lib/ocf/resource.d/wraptest/docker-wrap.dbug" >> /usr/lib/ocf/resource.d/wraptest/WrapDummy
	echo "/usr/lib/ocf/resource.d/heartbeat/Dummy \$@"  >> /usr/lib/ocf/resource.d/wraptest/WrapDummy
	chmod 755 /usr/lib/ocf/resource.d/wraptest/WrapDummy

	export OCF_RESKEY_CRM_meta_provider="wraptest"
	# try more complex args here. like ''' my arg ''' 
	export OCF_RESKEY_myarg1='HA ^(?!amq\.).* {"ha-mode":"all"}'
	export OCF_RESKEY_myarg2='$(ls)'
	export OCF_RESKEY_myarg3='`ls`'
	export OCF_RESKEY_myarg4="\$HOME"
	export OCF_RESKEY_CRM_meta_type="WrapDummy"
	export OCF_RESKEY_pcmk_docker_run_opts="-v /usr/lib/ocf/resource.d/wraptest:/usr/lib/ocf/resource.d/wraptest"

	docker_exec "stop" "0"
	docker_exec "start" "0"
	docker_exec "monitor" "0"

	cat /usr/lib/ocf/resource.d/wraptest/docker-wrap.dbug | grep "OCF"
	myarg=$(cat /usr/lib/ocf/resource.d/wraptest/docker-wrap.dbug | grep "OCF_RESKEY_myarg1" | awk -F= '{print$2}')
	echo "DID ARG PASS?  $myarg == $OCF_RESKEY_myarg1"
	if ! [ "$myarg" = "$OCF_RESKEY_myarg1" ]; then
		echo "ERROR: arguments [$OCF_RESKEY_myarg1]did not get passed to isolated instance"
		exit 1
	fi

	myarg=$(cat /usr/lib/ocf/resource.d/wraptest/docker-wrap.dbug | grep "OCF_RESKEY_myarg2" | awk -F= '{print$2}')
	echo "DID ARG PASS?  $myarg == $OCF_RESKEY_myarg2"
	if ! [ "$myarg" = "$OCF_RESKEY_myarg2" ]; then
		echo "ERROR: arguments [$OCF_RESKEY_myarg2]did not get passed to isolated instance"
		exit 1
	fi

	myarg=$(cat /usr/lib/ocf/resource.d/wraptest/docker-wrap.dbug | grep "OCF_RESKEY_myarg3" | awk -F= '{print$2}')
	echo "DID ARG PASS?  $myarg == $OCF_RESKEY_myarg3"
	if ! [ "$myarg" = "$OCF_RESKEY_myarg3" ]; then
		echo "ERROR: arguments [$OCF_RESKEY_myarg3]did not get passed to isolated instance"
		exit 1
	fi


	myarg=$(cat /usr/lib/ocf/resource.d/wraptest/docker-wrap.dbug | grep "OCF_RESKEY_myarg4" | awk -F= '{print$2}')
	echo "DID ARG PASS?  $myarg == $OCF_RESKEY_myarg4"
	if ! [ "$myarg" = "$OCF_RESKEY_myarg4" ]; then
		echo "ERROR: arguments [$OCF_RESKEY_myarg4]did not get passed to isolated instance"
		exit 1
	fi

# var/lib/docker/devicemapper/mnt/$(docker inspect --format {{.ID}} $container)/rootfs/tmp/docker-wrap.dbug


	docker_exec "stop" "0"
	docker_exec "monitor" "7"
}

test_rsc_failure_detection()
{
	default_vars
	curtest="rsc_failure_detection"

	docker_exec "monitor" "7"
	docker_exec "start" "0"
	docker_exec "monitor" "0"

	echo "rm -f /var/run/resource-agents/Dummy-*" | nsenter --target $(docker inspect --format {{.State.Pid}} $container) --mount --uts --ipc --net --pid

	docker_exec "monitor" "7"
	docker_exec "stop" "0"
	docker_exec "monitor" "7"
	docker_exec "start" "0"
	docker_exec "stop" "0"
}

test_multi_rsc()
{
	default_vars
	curtest="multi_rsc"

	docker_exec "monitor" "7"
	docker_exec "start" "0"
	docker_exec "monitor" "0"

	export OCF_RESOURCE_INSTANCE="test2"
	docker_exec "monitor" "7"
	docker_exec "start" "0"
	docker_exec "monitor" "0"

	docker_exec "stop" "0"
	val=$(docker inspect --format {{.State.Running}} $container 2>/dev/null)
	if [ $? -ne 0 ]; then
		#not running as a result of container not being found
		echo "FAILED: test $curtest: container shouldn't have stopped"
		exit 1
	fi

	export OCF_RESOURCE_INSTANCE="test"
	docker_exec "monitor" "0"
	docker_exec "stop" "0"

	val=$(docker inspect --format {{.State.Running}} $container 2>/dev/null)
	if [ $? -eq 0 ]; then
		#not running as a result of container not being found
		echo "FAILED: test $curtest: container should be stopped now"
		exit 1
	fi
}


test_super_multi_rsc()
{
	default_vars
	curtest="super_multi_rsc"
	resources=9

	for (( c=1; c <= $resources; c++ ))
	do
		export OCF_RESOURCE_INSTANCE="test${c}"

		docker_exec "monitor" "7"
		docker_exec "start" "0"
		docker_exec "monitor" "0"

	done

	for (( c=1; c <= $resources; c++ ))
	do
		export OCF_RESOURCE_INSTANCE="test${c}"
		docker_exec "monitor" "0"
	done

	for (( c=1; c <= $resources; c++ ))
	do
		export OCF_RESOURCE_INSTANCE="test${c}"
		docker_exec "stop" "0"

		val=$(docker inspect --format {{.State.Running}} $container 2>/dev/null)
		rc=$?
		if [ $rc -ne 0 ] && [ $c -ne $resources ]; then
			echo "FAILED: test $curtest: container shouldn't have stopped yet. resource $OCF_RESOURCE_INSTANCE stopped last"
			exit 1
		elif [ $rc -eq 0 ] && [ $c -eq $resources ]; then
			echo "FAILED: test $curtest: container should be stopped now"
			exit 1
		fi
		docker_exec "monitor" "7"
	done

}


test_super_multi_rsc_failure()
{
	default_vars
	curtest="super_multi_rsc_failure"
	local resources=9
	local index

	for (( c=1; c <= $resources; c++ ))
	do
		export OCF_RESOURCE_INSTANCE="test${c}"

		docker_exec "monitor" "7"
		docker_exec "start" "0"

		fail_it=$(( $RANDOM % 2 ))
		if [ $fail_it -eq 1 ]; then
			echo "FAILING INDEX $c"
			echo "rm -f /var/run/resource-agents/Dummy-test${c}.state" | nsenter --target $(docker inspect --format {{.State.Pid}} $container) --mount --uts --ipc --net --pid
			docker_exec "monitor" "7"
		fi
	done

	for (( c=1; c <= $resources; c++ ))
	do
		export OCF_RESOURCE_INSTANCE="test${c}"
		/usr/lib/ocf/resource.d/isolation/docker-wrapper "monitor"
		if [ $? -ne 0 ]; then
			docker_exec "stop" "0"
			docker_exec "monitor" "7"
			docker_exec "start" "0"
			docker_exec "monitor" "0"
		fi
	done

	for (( c=1; c <= $resources; c++ ))
	do
		export OCF_RESOURCE_INSTANCE="test${c}"
		docker_exec "monitor" "0"
		docker_exec "stop" "0"

		val=$(docker inspect --format {{.State.Running}} $container 2>/dev/null)
		rc=$?
		if [ $rc -ne 0 ] && [ $c -ne $resources ]; then
			echo "FAILED: test $curtest: container shouldn't have stopped yet. resource $OCF_RESOURCE_INSTANCE stopped last"
			exit 1
		elif [ $rc -eq 0 ] && [ $c -eq $resources ]; then
			echo "FAILED: test $curtest: container should be stopped now"
			exit 1
		fi
		docker_exec "monitor" "7"
	done

}

test_loop()
{
	test_simple
	echo "PASSED: $curtest"

	test_rsc_failure_detection
	echo "PASSED: $curtest"

	test_failure_detection_pid1
	echo "PASSED: $curtest"

	test_failure_invalid_image
	echo "PASSED: $curtest"

	test_arg_passing
	echo "PASSED: $curtest"

	test_failure_detection
	echo "PASSED: $curtest"

	test_multi_rsc
	echo "PASSED: $curtest"

	test_super_multi_rsc
	echo "PASSED: $curtest"

	test_super_multi_rsc_failure
	echo "PASSED: $curtest"
}


service docker start > /dev/null 2>&1
build_image
echo "STARTING TESTS: using image <$image> container name <$container>"

export OCF_RESKEY_pcmk_docker_privileged="true"
test_loop

unset OCF_RESKEY_pcmk_docker_privileged
test_loop

#cleanup

echo "______ ALL TESTS PASSED ______"
