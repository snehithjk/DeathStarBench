#!/bin/bash

# 1 - disable changes
disableDockerChanges=0

# Check for the --disable-docker-changes flag
for arg in "$@"
do
    if [ "$arg" == "--disable-docker-changes" ]; then
        disableDockerChanges=1
    fi
done

ip=54.212.60.8
numRuns=5
connections=(100 100 100)
rates=(1500 2000 2400)
dockerContainerId="a4ed8752c0e2"
enableDockerChangeAfter=50  # Time in seconds to enable Docker changes after the wrk command starts
disableDockerChangeAfter=70  # Time in seconds to disable Docker changes after the wrk command starts

for idx in ${!connections[@]}; do
    c=${connections[$idx]}
    r=${rates[$idx]}
    echo "Test $idx: c=$c, r=$r"

    for ((iter=0; iter<$numRuns; iter++)); do
        echo "Starting run $iter for test $idx..."

        # SSH into the server and start the collector
        ssh -f -i ./mac.pem ubuntu@$ip "sudo nohup ./collector.sh 0 ~/collectorOutput/collector_${c}_${r}_${iter}.txt & \
        sudo nohup collectl -scmDn --export lexpr > ~/collectlOutput/collectl_${c}_${r}_${iter}.txt &"

        # Start the wrk command in the background and mark the start time
        wrkStartTime=$(date +%s)
        ./DeathStarBench/wrk2/wrk -D exp -t 8 -c $c -d 120 -L -s ./DeathStarBench/hotelReservation/wrk2/scripts/hotel-reservation/mixed-workload_type_1.lua http://$ip:5000 -R $r > wrk2_${c}_${r}_${iter}.txt &
        wrkPid=$!

        # Monitor the wrk command and perform Docker changes at specified times if enabled
        dockerChanged=0
        while kill -0 $wrkPid 2> /dev/null; do
            currentTime=$(date +%s)
            elapsedTime=$((currentTime - wrkStartTime))

            if [ $disableDockerChanges -eq 0 ] && [ $dockerChanged -eq 0 ] && [ $elapsedTime -ge $enableDockerChangeAfter ]; then
                echo "Enabling Docker changes..."
                ssh -i ./mac.pem ubuntu@$ip "docker exec $dockerContainerId mongo --eval \"db = db.getSiblingDB('reservation-db'); db.reservation.renameCollection('reservation1', true);\""
                dockerChanged=1
            fi

            if [ $disableDockerChanges -eq 0 ] && [ $dockerChanged -eq 1 ] && [ $elapsedTime -ge $disableDockerChangeAfter ]; then
                echo "Disabling Docker changes..."
                ssh -i ./mac.pem ubuntu@$ip "docker exec $dockerContainerId mongo --eval \"db = db.getSiblingDB('reservation-db'); db.reservation1.renameCollection('reservation', true);\""
                break
            fi

            sleep 1  # Sleep to prevent tight looping
        done

        # Wait for the wrk command to complete
        wait $wrkPid
        wrkEndTime=$(date +%s)
        totalWrkTime=$((wrkEndTime - wrkStartTime))
        echo "wrk script execution for run $iter for test $idx completed in $totalWrkTime seconds."

        # SSH into the server and stop the collector and collectl
        ssh -i ./mac.pem ubuntu@$ip 'sudo pkill collector.sh; sudo pkill collectl'

        echo "Run $iter for test $idx completed."
        sleep 5  # Pause for 5 seconds before the next run
    done

    echo "..Test $idx Complete!"
done
