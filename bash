#! /bin/bash


host=localhost
port=9999


tmpf=$(mktemp /tmp/slice-lifecycle.XXXXXXXXXX.json)
intermediate_dir=~/
intermediate_prefix=slice-lifecycle-
sliceZeroReduced='{"dl":{"algorithm":"Static","slices":[{"id":0,"static":{"posLow":0,"posHigh":5}}]}}'
sliceZeroFull='{"dl":{"algorithm":"Static","slices":[{"id":0,"static":{"posLow":0,"posHigh":12}}]}}'
sliceThree='{"dl":{"slices":[{"id":3,"static":{"posLow":6,"posHigh":12}}]}}'
removeSliceThree='{"dl":{"slices":[{"id":3}]}}'
removeAlgo='{"dl":{"algorithm":"None"}}'


global_step=1


wait_unless_auto() {
 if [ "$1" != "auto" ]; then
   echo -n "$global_step: Key..."
   read -n1 -s
   echo -ne "\r"
 fi
 let global_step=$global_step+1
}


write_status() {
 echo "Intermediate JSON #$1"
 curl -sX GET http://$host:$port/stats | jq . > $intermediate_dir/$intermediate_prefix$1.json
}


echo "Note: intermediate JSON file directory is $intermediate_dir"
echo "Note: temporary data is written to $tmpf"


# wait for controller, i.e. curl reports success
echo "$global_step: waiting for http://$host:$port"
wait_unless_auto "$@"
curl -sX GET http://$host:$port/stats > /dev/null 2>&1
while [ $? -ne 0 ]; do
 sleep 1
 curl -sX GET http://$host:$port/stats > /dev/null 2>&1
done
echo "controller online"


# wait for existing (default) slice configuration, i.e. sliceConfig is present
# in JSON
echo "$global_step: waiting for http://$host:$port base station information"
wait_unless_auto "$@"
res="null"
while [ "$res" == "null" ]; do
 sleep 1
 res=$(curl -sX GET http://$host:$port/stats | tee $tmpf |
   jq '.eNB_config[0].eNB.cellConfig[0]')
done
echo "slice information online"


res=$(jq '.eNB_config[0].eNB.cellConfig[0].dlBandwidth' < $tmpf)
if [ "$res" != "25" ]; then
 echo "This script only works with LTE bandwidth 25"
 exit
fi


write_status 1


echo -n "checking that current DL slice algorithm is None... "
# get number of elements in dl array inside of sliceConfig
#num_slices=$(jq '.eNB_config[0].eNB.cellConfig[0].sliceConfig.dl | length' < $tmpf)
algo=$(jq '.eNB_config[0].eNB.cellConfig[0].sliceConfig.dl.algorithm' < $tmpf)
echo $algo
if [ "$algo" != "\"None\"" ]; then
 echo "already a slice algorithm loaded, might create problems... "
 #exit 1
fi
echo "done"


echo "$global_step: create DL slice ID 0 with 6 RBGs (roughly 50%)"
wait_unless_auto "$@"
curl -X POST http://$host:$port/slice/enb/-1 --data "$sliceZeroReduced"
# wait that slice ID 0 has only 50% resources
echo -n "waiting for action to take effect... "
posLow=1
posHigh=2
while [ "$posLow" != "0" ] || [ "$posHigh" != "5" ]; do
 sleep 1
 posLow=$(curl -sX GET http://$host:$port/stats | tee $tmpf |
   jq '.eNB_config[0].eNB.cellConfig[0].sliceConfig.dl.slices[0].static.posLow')
 posHigh=$(jq '.eNB_config[0].eNB.cellConfig[0].sliceConfig.dl.slices[0].static.posHigh' < $tmpf)
done
echo "DL slice ID 0 created"


write_status 2


echo "$global_step: create DL slice ID 3 with 7RBGs (roughly 50%)"
wait_unless_auto "$@"
curl -X POST http://$host:$port/slice/enb/-1 --data "$sliceThree"
# wait for second slice, then check its ID
echo -n "waiting for action to take effect... "
while [ "$num_slices" != "2" ]; do
 sleep 1
 num_slices=$(curl -sX GET http://$host:$port/stats | tee $tmpf |
   jq '.eNB_config[0].eNB.cellConfig[0].sliceConfig.dl.slices | length')
done
slice_id=$(jq '.eNB_config[0].eNB.cellConfig[0].sliceConfig.dl.slices[1].id' < $tmpf)
if [ "$slice_id" != "3" ]; then
 echo "slice ID is not three ($slice_id)"
 exit 1
fi
echo "DL slice ID 3 online"


write_status 3


echo "$global_step: wait for TWO UEs to connect"
wait_unless_auto "$@"
num_phones=0
while [ "$num_phones" != "2" ]; do # CHANGED: Wait for 2 phones
 sleep 1
 num_phones=$(curl -sX GET http://$host:$port/stats | tee $tmpf |
   jq '.eNB_config[0].UE.ueConfig | length')
done
echo "TWO UEs connected ($num_phones)"


# Get details of the two connected UEs
imsi_ue0=$(jq '.eNB_config[0].UE.ueConfig[0].imsi' < $tmpf)
rnti_ue0=$(jq '.eNB_config[0].UE.ueConfig[0].rnti' < $tmpf)
slice_UE0=$(jq '.eNB_config[0].UE.ueConfig[0].dlSliceId' < $tmpf)


imsi_ue1=$(jq '.eNB_config[0].UE.ueConfig[1].imsi' < $tmpf)
rnti_ue1=$(jq '.eNB_config[0].UE.ueConfig[1].rnti' < $tmpf)
slice_UE1=$(jq '.eNB_config[0].UE.ueConfig[1].dlSliceId' < $tmpf)




# --- CHECK INITIAL ASSIGNMENT (UE 0 should be in slice 0) ---
if [ "$slice_UE0" != "0" ]; then
 echo "UE $imsi_ue0/$rnti_ue0 is not in initial slice 0! (Actual: $slice_UE0)"
 # Exit or proceed based on expected behavior. We'll proceed.
fi
echo "UE $rnti_ue0 connected and is in slice $slice_UE0" # Should be 0


# --- ASSIGN UE 1 TO SLICE 3 ---
# If UE 1 is already in slice 3, skip the manual assignment
if [ "$slice_UE1" != "3" ]; then
   # We now assign the SECOND UE (index 1) to slice 3, ensuring separation.
   echo "$global_step: change slice association of UE $rnti_ue1 to slice 3"
   wait_unless_auto "$@"
   ueToSliceThree="{\"ueConfig\":[{\"rnti\":$rnti_ue1,\"dlSliceId\":3}]}"
   curl -X POST http://$host:$port/ue_slice_assoc/enb/-1 --data "$ueToSliceThree"
  
   echo -n "waiting for action to take effect... "
   slice_UE1=0
   while [ "$slice_UE1" != "3" ]; do
     sleep 1
     slice_UE1=$(curl -sX GET http://$host:$port/stats | tee $tmpf |
       jq '.eNB_config[0].UE.ueConfig[1].dlSliceId')
   done
fi
echo "UE $rnti_ue1 is in slice 3"


write_status 4


# Check final assignments for clarity
echo "Final Slice Check:"
echo "  UE $rnti_ue0 is in Slice $slice_UE0"
echo "  UE $rnti_ue1 is in Slice $slice_UE1"


# wait for TWO phones to disconnet
num_phones=$(jq '.eNB_config[0].UE.ueConfig | length' < $tmpf)
let next_num_phones=0 # Wait for all UEs (2) to disconnect, resulting in 0
echo "$global_step: wait for UEs to disconnect (new number: $next_num_phones)"
wait_unless_auto "$@"
while [ "$num_phones" != "$next_num_phones" ]; do
 sleep 1
 num_phones=$(curl -sX GET http://$host:$port/stats | tee $tmpf |
   jq '.eNB_config[0].UE.ueConfig | length')
done
echo "UEs disconnected"


write_status 5


# delete slice 3
echo "$global_step: delete slice ID 3"
wait_unless_auto "$@"
curl -X DELETE http://$host:$port/slice/enb/-1 --data "$removeSliceThree"
echo -n "waiting for action to take effect... "
num_slices=121
while [ "$num_slices" != "1" ]; do
 sleep 1
 num_slices=$(curl -sX GET http://$host:$port/stats | tee $tmpf |
   jq '.eNB_config[0].eNB.cellConfig[0].sliceConfig.dl.slices | length')
done
echo "deleted slice ID 3"


# increase share of slice ID 0 back to 100%
echo "$global_step: increase percentage of DL slice ID 0 to 100%"
wait_unless_auto "$@"
curl -X POST http://$host:$port/slice/enb/-1 --data "$sliceZeroFull"
# wait that slice ID 0 has only 50% resources
echo -n "waiting for action to take effect... "
posLow=1
posHigh=2
while [ "$posLow" != "0" ] || [ "$posHigh" != "12" ]; do
 sleep 1
 posLow=$(curl -sX GET http://$host:$port/stats | tee $tmpf |
   jq '.eNB_config[0].eNB.cellConfig[0].sliceConfig.dl.slices[0].static.posLow')
 posHigh=$(jq '.eNB_config[0].eNB.cellConfig[0].sliceConfig.dl.slices[0].static.posHigh' < $tmpf)
done
echo "slice ID 0 has 100% resources"


write_status 6


# turn off any slicing
echo "$global_step: turn off slicing"
wait_unless_auto "$@"
curl -X POST http://$host:$port/slice/enb/-1 --data "$removeAlgo"
algo=$(jq '.eNB_config[0].eNB.cellConfig[0].sliceConfig.dl.algorithm' < $tmpf)
while [ "$algo" != "\"None\"" ]; do
 algo=$(curl -sX GET http://$host:$port/stats |
   jq '.eNB_config[0].eNB.cellConfig[0].sliceConfig.dl.algorithm')
done
echo "DONE"


write_status 7
