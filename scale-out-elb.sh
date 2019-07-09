#!/bin/sh

####################################################
# ELBでスケールアウト
# profileは適宜読み換える
# 作成されたインスタンスは名称がついていないので、MCから編集する
# LBにアタッチ前に確認したい場合、do_attachをfalseにすれば、EC2起動までで終わってくれます
####################################################
# 準備
profile="sandbox-user"
elb_name="sample-elb"
create_count="1"; # AZの中で増やしたい数(マルチAZで一台ずつ増やしたい場合は1を設定する)
do_attach="false"
## unicorn起動用のパラメーター
humidai="step" # ローカルのコンフィグで設定した踏み台のホスト名
ec2_user="ec2-user"
app_dir=""
environment="production"
exec_command="bundle exec unicorn -c config/$environment/unicorn.rb"


# ELB名称からELBの情報を返す
# parameter: <elb-name>
# return: describe-load-balancers
get_elb_info () {
  if [ $# != 1 ]; then
    echo "引数の数が間違っています！"
    exit 1
  fi

  local elb_info=`aws elb describe-load-balancers --load-balancer-name $1 --profile $profile`
  echo $elb_info
}

# インスタンスIDからAZのリストを返す
# parameter: <i-xxx i-yyy ...>
# return: <ap-northeast-1a ap-northeast-1c ...>
get_az_list () {
  local az_list=`aws ec2 describe-instances \
    --output json \
    --instance-ids $@ \
    --profile $profile \
    | jq -r '.Reservations[].Instances[].Placement.AvailabilityZone'`
  az_list=`delete_dup $az_list`
  echo $az_list
}

# 重複した要素を削除する
# parameter: <aaa bbb ccc aaa>
# return: <aaa bbb ccc>
delete_dup () {
  ary=$@

  result=()
  for i in $ary; do
    is_dup="false"
    for n in $result; do
      if [ $i == $n ]; then
        is_dup="true"
        break
      fi
    done
    if [ $is_dup == "false" ]; then
      result+=($i)
    fi
  done
  echo ${result[@]}
}

# AMI作成元のインスタンスを決める
# インスタンスIDを複数受け取って、重複AZのインスタンスは排除してインスタンスIDを返す
# parameter: <i-xxx i-yyy ...>
# return: <i-xxx i-yyy ...>
determine_origin_instance () {
  local instance_ids=$@
  local az_list=`get_az_list $instance_ids`
  local target_instance_id_array=()
  for az in $az_list; do
    # 一旦、Instances[0]で取れた一番最初のインスタンスをに絞るが、日付とかでsortした方がいいかも
    local instance_id=`aws ec2 describe-instances --instance-ids $instance_ids --output json \
      | jq -r '.Reservations[].Instances[0] \
      | select(.Placement.AvailabilityZone == "'$az'") \
      | .InstanceId'`
    target_instance_id_array+=($instance_id)
  done
  echo ${target_instance_id_array[@]}
}

# インスタンスのIDを受け取ってAMIを作成する
# parameter: <i-xxx>
# return: <ami-xxx>
create_image () {
  local instance_id=$1
  local date=`date +%Y%m%d%H%M%S`
  local instance_name=`aws ec2 describe-instances \
    --query 'Reservations[].Instances[].Tags[].Value' \
    --filter "Name=instance-id,Values=$instance_id" \
    --profile $profile --output text`
  local new_image_name=${instance_name}_$date
  local new_image=`aws ec2 create-image \
    --instance-id $instance_id \
    --name $new_image_name \
    --profile $profile \
    --no-reboot`
  ## 作成できなかったら終了
  if [ -z "$new_image" ] ; then
    echo "failer create image!"
    exit 1
  fi
  # イメージがavailableになるまで待つ
  local image_id=`echo $new_image | jq -r '.ImageId'`
  aws ec2 wait image-available --image-ids $image_id --profile $profile
  echo $image_id
}

# AMIからインスタンスを起動する。countの数だけ新しいインスタンスIDを返す。
# parameter: <ami-xxx i-xxx count>
# return: <i-aaa i-bbb ...>
run_instance () {
  local image_id=$1
  local instance_id=$2
  local count=$3
  ## コピー元のインスタンス情報を取得
  local origin_instance=`aws ec2 describe-instances --output json --instance-ids $instance_id --profile $profile`
  local security_groups=`echo $origin_instance | jq -r '.Reservations[].Instances[].SecurityGroups[].GroupId'`
  local instance_type=`echo $origin_instance | jq -r '.Reservations[].Instances[].InstanceType'`
  local vpc_id=`echo $origin_instance | jq -r '.Reservations[].Instances[].VpcId'`
  local subnet=`echo $origin_instance | jq -r '.Reservations[].Instances[].SubnetId'`
  local iam_role=`echo $origin_instance | jq -r '.Reservations[].Instances[].IamInstanceProfile.Arn'`
  local key_name=`echo $origin_instance | jq -r '.Reservations[].Instances[].KeyName'`
  ## AMIからec2を起動する
  local new_instances=`aws ec2 run-instances --image-id $image_id \
    --count $count \
    --security-group-ids $security_groups \
    --instance-type $instance_type \
    --subnet-id $subnet \
    --iam-instance-profile Arn=$iam_role \
    --key-name $key_name \
    --profile $profile`
  ## 作成できなかったら終了
  if [ -z "$new_instances" ] ; then
    echo "failer create instance!"
    exit 1
  fi
  ## インスタンスがrunningになるまで待つ
  local new_instance_ids=`echo $new_instances | jq -r '.Instances[].InstanceId'`
  aws ec2 wait instance-running --instance-ids $new_instance_ids --profile $profile
  echo $new_instance_ids
}

# # unicornを起動する
# parameter: <i-aaa i-bbb ...>
# return: <>
start_unicorn () {
  local ips=`echo $@ | jq -r '.Instances[].PublicIpAddress'`
  for ip in $ips; do
    ssh -t $humidai "ssh -t $ec2_user@$ip cd $app_dir $exec_command"
  done
  # ToDo 起動したか確認する
}

#############################実行部分################################

# step1
# ELB名からELBの情報を取得
elb_info=`get_elb_info $elb_name`
## なかったら終了
if [ -z "$elb_info" ] ; then
  echo "ELB is not exist."
  exit 1
fi

# step2
# ELBに紐付いたEC2を取得する
instance_ids=`echo $elb_info | jq -r '.LoadBalancerDescriptions[].Instances[].InstanceId'`
echo "ELBに紐づいたEC2：$instance_ids"
## なかったら終了
if [ -z "$instance_ids" ] ; then
  echo "instance is not exist."
  exit 1
fi

# step3
# AMI作成元のインスタンスを決める
origin_instance_ids=`determine_origin_instance $instance_ids`
echo "作成元のEC2：$origin_instance_ids"
## なかったら終了
if [ -z "$origin_instance_ids" ] ; then
  echo "targetable instance is not exist."
  exit 1
fi

# step4
# イメージの作成、インスタンスの作成、ELBへのアタッチ
# ToDo 一台ずつ作って待つのではなく、先に一気に作ってから待つ
for origin_instance_id in $origin_instance_ids; do
  # インスタンスのIDを指定してイメージを作成する
  new_image_id=`create_image $origin_instance_id`
  if [ $? == 1 ]; then
    echo "failer create instance!"
    exit 1
  fi
  echo "success create image($new_image_id)"

  # イメージからインスタンスを起動する
  target_instance_ids=`run_instance $new_image_id $origin_instance_id $create_count`
  if [ $? == 1 ]; then
    echo "failer create instance!"
    exit 1
  fi
  echo "success run instance($target_instance_ids)"

  # unicornを起動する
  # start_unicorn $target_instance_ids

  # ELBに instance をアタッチする
  if [ $do_attach == "true" ]; then
    aws elb register-instances-with-load-balancer \
      --profile $profile \
      --load-balancer-name $elb_name \
      --instances $target_instance_ids
    echo "---new EC2($target_instance_ids) attached!!---"
  fi
done

echo "---finish scale out---"