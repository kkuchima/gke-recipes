# **A3 VM on GKE ハンズオン-**
本ハンズオンでは A3 VM on GKE の初回セットアップ方法を説明します。

## **ハンズオン実施内容**
GKE のノードとして A3 VM を利用する手順は以下のとおりです。  

1. (Optional) A3 VM の CUD 購入、および予約の作成
2. (Optional) CUD の共有設定を有効化
3. VPC の作成
4. GKE クラスタの作成
5. テスト ワークロードの実行

手順 1 と 2 は Optional となるため本ハンズオンでは設定手順の説明を割愛します。  

## Google Cloud プロジェクトの設定、確認

### **1. 対象の Google Cloud プロジェクトを設定**

ハンズオンを行う Google Cloud プロジェクトのプロジェクト ID を環境変数に設定し、以降の手順で利用できるようにします。 (右辺の `testproject` を手動で置き換えてコマンドを実行します)

```bash
export PROJECT_ID=testproject
```

`プロジェクト ID` は [ダッシュボード](https://console.cloud.google.com/home/dashboard) に進み、左上の **プロジェクト情報** から確認します。

### **2. プロジェクトの課金が有効化されていることを確認する**

```bash
gcloud beta billing projects describe ${PROJECT_ID} \
  | grep billingEnabled
```

**Cloud Shell の承認** という確認メッセージが出た場合は **承認** をクリックします。

出力結果の `billingEnabled` が **true** になっていることを確認してください。

**false** の場合は、こちらのプロジェクトではハンズオンが**進められません**。別途、課金を有効化したプロジェクトを用意し、本ページの #1 の手順からやり直してください。

## **環境準備**

最初に、ハンズオンを進めるための環境準備を行います。

下記の設定を進めていきます。

- gcloud コマンドラインツール設定
- Google Cloud 機能（API）有効化設定

## **gcloud コマンドラインツール**

Google Cloud は、コマンドライン（CLI）、GUI から操作が可能です。ハンズオンでは作業の自動化を目的に主に CLI を使い作業を行います。

### **1. gcloud コマンドラインツールとは?**

gcloud コマンドライン インターフェースは、Google Cloud でメインとなる CLI ツールです。これを使用すると、多くの一般的なプラットフォーム タスクを様々なツールと組み合わせて実行することができます。

たとえば、gcloud CLI を使用して、以下のようなものを作成、管理できます。

- Google Compute Engine 仮想マシン
- Google Kubernetes Engine クラスタ

**ヒント**: gcloud コマンドラインツールについての詳細は[こちら](https://cloud.google.com/sdk/gcloud?hl=ja)をご参照ください。

### **2. gcloud から利用する Google Cloud のデフォルトプロジェクトを設定**

gcloud コマンドでは操作の対象とするプロジェクトの設定が必要です。操作対象のプロジェクトを設定します。

```bash
gcloud config set project ${PROJECT_ID}
```

承認するかどうかを聞かれるメッセージがでた場合は、`承認` ボタンをクリックします。

## **Google Cloud 環境設定**

### **1. API の有効化**
Google Cloud では利用したい機能（API）ごとに、有効化を行う必要があります。

ここでは、以降のハンズオンで利用する機能を事前に有効化しておきます。

```bash
gcloud services enable file.googleapis.com \
    container.googleapis.com \
    artifactregistry.googleapis.com
```

**GUI**: [API ライブラリ](https://console.cloud.google.com/apis/library)

## **1. VPC の作成**
A3 VM では GPUDirect-TCPX という独自のネットワーク スタックによってマルチノードの GPU 間通信の帯域幅を最大化しています。  
GPUDirect-TCPX を有効にした A3 VM では VM あたり 5 つの NIC を必要とします。  
同一の Compute ノードに複数の NIC をアタッチする場合、各 NIC は同一の VPC に属することができないため 5 つの VPC を用意する必要があります。それぞれの VPC の役割は以下の通りです。
* Primary VPC (1 つ)
    * Google Cloud の他サービスなどへの通信時に利用される
* Secondary VPC (4 つ)
    * 他ノードの GPU と直接通信する際に利用される

まず最初に本ハンズオンで利用する VPC を作成します。  

### **1-1. 環境変数の設定**

VPC 作成に必要となる環境変数を設定します。  

以下コマンドを実行してください。  
```bash
export REGION=asia-northeast1
export PRIMARY_VPC=primary-net
export PRIMARY_SUBNET=primary-subnet
export SECONDARY_VPC=data-net
export SECONDARY_SUBNET=data-sub
export CIDR=192.168
export SECONDARY_FW=fw-data-net-internal
```

### **1-2. プライマリ VPC の作成**

今回のハンズオン用 VPC を作成します。トラフィック最適化のためジャンボフレームを有効化します。  

```bash
gcloud compute networks create ${PRIMARY_VPC} \
  --subnet-mode=custom \
  --mtu=8244
```

作成した VPC にサブネットを作成します。

```bash
gcloud compute networks subnets create ${PRIMARY_SUBNET} \
  --network=${PRIMARY_VPC} \
  --region=${REGION} \
  --range=${CIDR}.0.0/24
```

### **1-3. セカンダリ VPC の作成**

GPU 間通信で利用するための VPC とサブネット、ファイアウォールルールを作成します。  

```bash
for N in $(seq 1 4); do
gcloud compute networks create ${SECONDARY_VPC}-$N \
    --subnet-mode=custom \
    --mtu=8244

gcloud compute networks subnets create ${SECONDARY_SUBNET}-$N \
    --network=${SECONDARY_VPC}-$N \
    --region=${REGION} \
    --range=${CIDR}.$N.0/24

gcloud compute firewall-rules create ${SECONDARY_FW}-$N \
  --network=${SECONDARY_VPC}-$N \
  --action=ALLOW \
  --rules=tcp:0-65535,udp:0-65535,icmp \
  --source-ranges=${CIDR}.0.0/16
done
```

## **2. GKE クラスタのデプロイ**

A3 VM を利用した GKE クラスタをデプロイします。  

### **2-1. 環境変数の設定**

GKE クラスタデプロイに必要な環境変数を設定します。  
`CLUSTER_VER` には以下のサポートされる GKE バージョンを指定します（最新情報は[公式ドキュメント](https://cloud.google.com/kubernetes-engine/docs/how-to/gpu-bandwidth-gpudirect-tcpx?hl=ja#requirements)を確認してください）。  
* GKE 1.27: 1.27.7-gke.1121000 以降
* GKE 1.28: 1.28.8-gke.1095000 以降
* GKE 1.29: 1.29.3-gke.1093000 以降

利用可能な GKE のバージョンは `gcloud container get-server-config --format "yaml(channels)" --zone asia-northeast1-b` コマンドで確認可能です（asia-northeast1-b ゾーン利用の例）。  

```bash
export CLUSTER_NAME=a3-cluster
export CLUSTER_VER=1.27.13-gke.1201000
export ZONE=asia-northeast1-b
export NODEPOOL_NAME=a3-pool
export NUM_NODES=2
```

### **2-2. GKE クラスタの作成**

Multi Networking が有効な GKE クラスタを作成します。  
また、データへのアクセスを容易にするため Filestore / GCS Fuse CSI ドライバーを有効にします。  

```bash
gcloud container clusters create ${CLUSTER_NAME} \
  --location=us-central1-a --cluster-version=${CLUSTER_VER} \
  --enable-dataplane-v2 --enable-ip-alias \
  --enable-multi-networking \
  --no-enable-autoupgrade \
  --enable-image-streaming \
  --workload-pool=${PROJECT_ID}.svc.id.goog \
  --addons=GcpFilestoreCsiDriver,GcsFuseCsiDriver
```

### **2-3. Multi-NIC の構成**

GKE クラスタで Multi-NIC を構成するために以下コマンドを実行します。  

```bash
kubectl apply -f - <<EOF
apiVersion: networking.gke.io/v1
kind: Network
metadata:
  name: vpc1
spec:
  parametersRef:
    group: networking.gke.io
    kind: GKENetworkParamSet
    name: vpc1
  type: Device
---
apiVersion: networking.gke.io/v1
kind: Network
metadata:
  name: vpc2
spec:
  parametersRef:
    group: networking.gke.io
    kind: GKENetworkParamSet
    name: vpc2
  type: Device
---
apiVersion: networking.gke.io/v1
kind: Network
metadata:
  name: vpc3
spec:
  parametersRef:
    group: networking.gke.io
    kind: GKENetworkParamSet
    name: vpc3
  type: Device
---
apiVersion: networking.gke.io/v1
kind: Network
metadata:
  name: vpc4
spec:
  parametersRef:
    group: networking.gke.io
    kind: GKENetworkParamSet
    name: vpc4
  type: Device
---
apiVersion: networking.gke.io/v1
kind: GKENetworkParamSet
metadata:
  name: vpc1
spec:
  vpc: ${SECONDARY_VPC}-1
  vpcSubnet: ${SECONDARY_SUBNET}-1
  deviceMode: NetDevice
---
apiVersion: networking.gke.io/v1
kind: GKENetworkParamSet
metadata:
  name: vpc2
spec:
  vpc: ${SECONDARY_VPC}-2
  vpcSubnet: ${SECONDARY_SUBNET}-2
  deviceMode: NetDevice
---
apiVersion: networking.gke.io/v1
kind: GKENetworkParamSet
metadata:
  name: vpc3
spec:
  vpc: ${SECONDARY_VPC}-3
  vpcSubnet: ${SECONDARY_SUBNET}-3
  deviceMode: NetDevice
---
apiVersion: networking.gke.io/v1
kind: GKENetworkParamSet
metadata:
  name: vpc4
spec:
  vpc: ${SECONDARY_VPC}-4
  vpcSubnet: ${SECONDARY_SUBNET}-4
  deviceMode: NetDevice
EOF
```

### **2-4. A3 Node Pool の作成**

A3 VM の Node Pool を作成します。  

```bash
gcloud container node-pools create ${NODEPOOL_NAME} \
    --cluster=${CLUSTER_NAME} \
    --zone=${ZONE} \
    --machine-type=a3-highgpu-8g \
    --num-nodes=${NUM_NODES} \
    --accelerator=type=nvidia-h100-80gb,count=8,gpu-driver-version=LATEST \
    --additional-node-network=network=${SECONDARY_VPC}-1,subnetwork=${SECONDARY_SUBNET}-1 \
    --additional-node-network=network=${SECONDARY_VPC}-2,subnetwork=${SECONDARY_SUBNET}-2 \
    --additional-node-network=network=${SECONDARY_VPC}-3,subnetwork=${SECONDARY_SUBNET}-3 \
    --additional-node-network=network=${SECONDARY_VPC}-4,subnetwork=${SECONDARY_SUBNET}-4 \
    --enable-gvnic \
    --no-enable-autoupgrade
```

Node Pool プロビジョニング完了後、`kubectl describe node` コマンドで Node に GPU が割り当てられていることを確認します。  

```text
kubectl get nodes

kubectl describe node <Node Name>

// 出力例
Capacity:
  ...
  nvidia.com/gpu:             8
Allocatable:
  ...
  nvidia.com/gpu:             8
```

### **2-5. NCCL Plugin のインストール**

GPUDirect-TCPX 用の NCCL Plugin を GKE クラスタのノードにインストールします。  

```bash
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/gpudirect-tcpx/nccl-tcpx-installer.yaml
```

以下コマンドを実行し、正常に NCCL Plugin がインストールされていることを確認します。  

```bash
kubectl get pods -n=kube-system -l=name=nccl-tcpx-installer
```

## **3. テストワークロードの実行**

テストワークロードをデプロイし、NCCL と GPUDirect-TCPX が期待どおりに動作することを確認します。  
このワークロードには、Pod が GPUDirect-TCPX を使用できるようにするサービスを実行する tcpx-daemon というサイドカーコンテナが含まれています。このサイドカーコンテナは、GPUDirect-TCPX を使用するワークロード Pod に追加する必要があります。  
詳細については[公式ドキュメント](https://cloud.google.com/kubernetes-engine/docs/how-to/gpu-bandwidth-gpudirect-tcpx?hl=ja#test-workload)も合わせてご確認ください。  

### **3-1. テストワークロードのデプロイ**

ConfigMap とテスト ワークロードをデプロイします。  

```bash
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/gpudirect-tcpx/nccl-config.yaml

kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/gpudirect-tcpx/nccl-test.yaml
```

### **3-2. all-gather テストの実行**

次のコマンドを実行して、ノードの NCCL all-gather テストをトリガーします。  

```bash
kubectl exec --stdin --tty --container=nccl-test nccl-test-host-1 -- /configs/allgather.sh nccl-host-1 nccl-host-2
```

出力は次のようになります。  

```text
#                                                              out-of-place                       in-place
#       size         count      type   redop    root     time   algbw   busbw #wrong     time   algbw   busbw #wrong
#        (B)    (elements)                               (us)  (GB/s)  (GB/s)            (us)  (GB/s)  (GB/s)
     1048576         16384     float    none      -1    696.8    1.50    1.41      0    729.0    1.44    1.35      0
     2097152         32768     float    none      -1    776.4    2.70    2.53      0    726.7    2.89    2.71      0
     4194304         65536     float    none      -1    774.3    5.42    5.08      0    805.1    5.21    4.88      0
     8388608        131072     float    none      -1    812.1   10.33    9.68      0    817.6   10.26    9.62      0
    16777216        262144     float    none      -1   1035.2   16.21   15.19      0   1067.8   15.71   14.73      0
    33554432        524288     float    none      -1   1183.3   28.36   26.59      0   1211.8   27.69   25.96      0
    67108864       1048576     float    none      -1   1593.4   42.12   39.49      0   1510.5   44.43   41.65      0
   134217728       2097152     float    none      -1   2127.8   63.08   59.13      0   2312.7   58.03   54.41      0
   268435456       4194304     float    none      -1   3603.0   74.50   69.85      0   3586.2   74.85   70.17      0
   536870912       8388608     float    none      -1   7101.7   75.60   70.87      0   7060.9   76.03   71.28      0
# Out of bounds values : 0 OK
# Avg bus bandwidth    : 29.8293
```



## **(Optional) Filestore PV の作成**

GKE から低遅延でデータにアクセスさせたい場合、データの格納場所として Filestore が 1 つの選択肢となります。  
本セクションでは、Filestore CSI を利用した PV の作成を行います。  

### **1. Storage Class の作成**

GKE の Primary VPC 上に Filestore インスタンスをプロビジョニングするために、以下の Storage Class をデプロイします。  

```bash
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: sc-filestore
provisioner: filestore.csi.storage.gke.io
volumeBindingMode: Immediate
allowVolumeExpansion: true
parameters:
  tier: ENTERPRISE
  network: ${PRIMARY_VPC}
EOF
```

### **2. サンプルワークロードの作成**

Filstore PV を要求する Pod をデプロイします。  

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-server-deployment
  labels:
    app: nginx
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx
        volumeMounts:
        - mountPath: /usr/share/nginx/html
          name: mypvc
      volumes:
      - name: mypvc
        persistentVolumeClaim:
          claimName: pvc-filestore
---
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: pvc-filestore
spec:
  accessModes:
  - ReadWriteMany
  storageClassName: sc-filestore
  resources:
    requests:
      storage: 1Ti
EOF
```
