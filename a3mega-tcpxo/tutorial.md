# **A3 Mega VM on GKE ハンズオン-**

本ハンズオンでは A3 Mega VM on GKE の初回セットアップ方法について説明します。  

## **ハンズオン実施内容**
GKE のノードとして A3 Mega VM を利用する手順は以下の通りです。  

1. VPC の作成
2. GKE クラスタの作成
3. テスト ワークロードの実行

必要に応じて、本手順実施前に A3 Mega VM の CUD 購入、および予約の作成や CUD の共有設定を有効化してください。  
本ハンズオンでは CUD や予約関連の設定手順の説明は割愛します。  

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
A3 Mega VM では GPUDirect-TCPXO という独自のネットワーク スタックによってマルチノードの GPU 間通信の帯域幅を最大化しています。  
GPUDirect-TCPXO を有効にした A3 Mega VM では VM あたり 9 つの NIC を必要とします。  
同一の Compute ノードに複数の NIC をアタッチする場合、各 NIC は同一の VPC に属することができないため 9 つの VPC を用意する必要があります。それぞれの VPC の役割は以下の通りです。
* Primary VPC (1 つ)
    * Google Cloud の他サービスなどへの通信時に利用される
* Secondary VPC (8 つ)
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
export SECONDARY_SUBNET=data-subnet
export CIDR=192.168
export SECONDARY_FW=fw-data-net-internal
```

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
以下のコマンドをコピーし、Cloud Shell に貼り付けてください。  

```text
for N in $(seq 1 8); do
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

A3 Mega VM を利用した GKE クラスタをデプロイします。  

### **2-1. 環境変数の設定**

GKE クラスタデプロイに必要な環境変数を設定します。  
`CLUSTER_VER` には以下のサポートされる GKE バージョンを指定します（最新情報は[公式ドキュメント](https://cloud.google.com/kubernetes-engine/docs/how-to/gpu-bandwidth-gpudirect-tcpx?hl=ja#requirements)を確認してください）。  
* GKE 1.28: 1.28.9-gke.1250000 以降
* GKE 1.29: 1.29.4-gke.1542000 以降
* GKE 1.30: 1.30.4-gke.1129000 以降

利用可能な GKE のバージョンは `gcloud container get-server-config --format "yaml(channels)" --zone asia-northeast1-b` コマンドで確認可能です（asia-northeast1-b ゾーン利用の例）。  

```bash
export CLUSTER_NAME=a3mega-cluster
export CLUSTER_VER=1.30.5-gke.1014001
export ZONE=asia-northeast1-b
export NODEPOOL_NAME=a3mega-pool
export NUM_NODES=2
```

### **2-2. GKE クラスタの作成**

Multi Networking が有効な GKE クラスタを作成します。  
また、データへのアクセスを容易にするため Filestore / GCS Fuse CSI ドライバーを有効にします。  

```bash
gcloud container beta clusters create ${CLUSTER_NAME} \
  --location=${ZONE} --cluster-version=${CLUSTER_VER} \
  --enable-dataplane-v2 --enable-ip-alias \
  --enable-multi-networking \
  --no-enable-autoupgrade \
  --enable-image-streaming \
  --workload-pool=${PROJECT_ID}.svc.id.goog \
    --network=${PRIMARY_VPC} --subnetwork=${PRIMARY_SUBNET} \
  --addons=GcpFilestoreCsiDriver,GcsFuseCsiDriver
```

### **2-3. Multi-NIC の構成**

GKE クラスタで Multi-NIC を構成するために以下コマンドを実行します。  

```text
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
kind: Network
metadata:
  name: vpc5
spec:
  parametersRef:
    group: networking.gke.io
    kind: GKENetworkParamSet
    name: vpc5
  type: Device
---
apiVersion: networking.gke.io/v1
kind: Network
metadata:
  name: vpc6
spec:
  parametersRef:
    group: networking.gke.io
    kind: GKENetworkParamSet
    name: vpc6
  type: Device
---
apiVersion: networking.gke.io/v1
kind: Network
metadata:
  name: vpc7
spec:
  parametersRef:
    group: networking.gke.io
    kind: GKENetworkParamSet
    name: vpc7
  type: Device
---
apiVersion: networking.gke.io/v1
kind: Network
metadata:
  name: vpc8
spec:
  parametersRef:
    group: networking.gke.io
    kind: GKENetworkParamSet
    name: vpc8
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
---
apiVersion: networking.gke.io/v1
kind: GKENetworkParamSet
metadata:
  name: vpc5
spec:
  vpc: ${SECONDARY_VPC}-5
  vpcSubnet: ${SECONDARY_SUBNET}-5
  deviceMode: NetDevice
---
apiVersion: networking.gke.io/v1
kind: GKENetworkParamSet
metadata:
  name: vpc6
spec:
  vpc: ${SECONDARY_VPC}-6
  vpcSubnet: ${SECONDARY_SUBNET}-6
  deviceMode: NetDevice
---
apiVersion: networking.gke.io/v1
kind: GKENetworkParamSet
metadata:
  name: vpc7
spec:
  vpc: ${SECONDARY_VPC}-7
  vpcSubnet: ${SECONDARY_SUBNET}-7
  deviceMode: NetDevice
---
apiVersion: networking.gke.io/v1
kind: GKENetworkParamSet
metadata:
  name: vpc8
spec:
  vpc: ${SECONDARY_VPC}-8
  vpcSubnet: ${SECONDARY_SUBNET}-8
  deviceMode: NetDevice
EOF
```

### **2-4. A3 Mega Node Pool の作成**

A3 Mega VM の Node Pool を作成します。  

```bash
gcloud beta container node-pools create ${NODEPOOL_NAME} \
    --cluster=${CLUSTER_NAME} \
    --zone=${ZONE} \
    --machine-type=a3-megagpu-8g \
    --num-nodes=${NUM_NODES} \
    --accelerator=type=nvidia-h100-mega-80gb,count=8,gpu-driver-version=LATEST \
    --additional-node-network=network=${SECONDARY_VPC}-1,subnetwork=${SECONDARY_SUBNET}-1 \
    --additional-node-network=network=${SECONDARY_VPC}-2,subnetwork=${SECONDARY_SUBNET}-2 \
    --additional-node-network=network=${SECONDARY_VPC}-3,subnetwork=${SECONDARY_SUBNET}-3 \
    --additional-node-network=network=${SECONDARY_VPC}-4,subnetwork=${SECONDARY_SUBNET}-4 \
    --additional-node-network=network=${SECONDARY_VPC}-5,subnetwork=${SECONDARY_SUBNET}-5 \
    --additional-node-network=network=${SECONDARY_VPC}-6,subnetwork=${SECONDARY_SUBNET}-6 \
    --additional-node-network=network=${SECONDARY_VPC}-7,subnetwork=${SECONDARY_SUBNET}-7 \
    --additional-node-network=network=${SECONDARY_VPC}-8,subnetwork=${SECONDARY_SUBNET}-8 \
    --enable-gvnic \
    --no-enable-autoupgrade \
    --scopes "https://www.googleapis.com/auth/cloud-platform"
```

Node Pool プロビジョニング完了後、Node に GPU が割り当てられていることを確認します。  

以下のコマンドを実行し、A3 Mega Node の名前を確認します。  

```bash
kubectl get nodes
```

`kubectl describe node` コマンドを実行し、GPU の割り当て状況を確認します。  

```text
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

GPUDirect-TCPXO 用の NCCL Plugin を GKE クラスタのノードにインストールします。  

```bash
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/gpudirect-tcpxo/nccl-tcpxo-installer.yaml
```

以下コマンドを実行し、正常に NCCL Plugin がインストールされていることを確認します。  

```bash
kubectl get pods -n=kube-system -l=name=nccl-tcpxo-installer
```

## **3. NRI device injector plugin のインストール**

コンテナに GPU をインジェクトするための NRI device injector plugin を GKE クラスタのノードにインストールします。

```bash
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/nri_device_injector/nri-device-injector.yaml
```

以下コマンドを実行し、正常に NCCL Plugin がインストールされていることを確認します。  

```bash
kubectl get pods -n=kube-system -l=name=device-injector
```

## **4. テストワークロードの実行**

テストワークロードをデプロイし、NCCL と GPUDirect-TCPXO が期待どおりに動作することを確認します。  
このワークロードには、Pod が GPUDirect-TCPXO を使用できるようにするサービスを実行する tcpxo-daemon というサイドカーコンテナが含まれています。このサイドカーコンテナは、GPUDirect-TCPXO を使用するワークロード Pod に追加する必要があります。  
詳細については[公式ドキュメント](https://cloud.google.com/kubernetes-engine/docs/how-to/gpu-bandwidth-gpudirect-tcpx#test-workload)も合わせてご確認ください。  

### **4-1. テストワークロードのデプロイ**

テスト ワークロード用の Pod をデプロイします。  

```bash
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/gpudirect-tcpxo/nccl-test-latest.yaml
```

### **4-2. all-gather テストの実行**

次のコマンドを実行して、ノードの NCCL all-gather テストをトリガーします。  

```bash
kubectl exec --stdin --tty --container=nccl-test nccl-test-host-1 -- /scripts/allgather.sh nccl-host-1 nccl-host-2
```

出力は次のようになります。  

```text
#
#                                                              out-of-place                       in-place          
#       size         count      type   redop    root     time   algbw   busbw #wrong     time   algbw   busbw #wrong
#        (B)    (elements)                               (us)  (GB/s)  (GB/s)            (us)  (GB/s)  (GB/s)       
          0             0     float    none      -1     0.24    0.00    0.00      0     0.18    0.00    0.00      0
          0             0     float    none      -1     0.19    0.00    0.00      0     0.17    0.00    0.00      0
          0             0     float    none      -1     0.17    0.00    0.00      0     0.17    0.00    0.00      0
          0             0     float    none      -1     0.17    0.00    0.00      0     0.17    0.00    0.00      0
          0             0     float    none      -1     0.17    0.00    0.00      0     0.17    0.00    0.00      0
        256             4     float    none      -1    235.2    0.00    0.00      0    235.1    0.00    0.00      0
        512             8     float    none      -1    241.0    0.00    0.00      0    236.1    0.00    0.00      0
       1024            16     float    none      -1    236.3    0.00    0.00      0    233.3    0.00    0.00      0
       2048            32     float    none      -1    234.1    0.01    0.01      0    233.4    0.01    0.01      0
       4096            64     float    none      -1    237.1    0.02    0.02      0    235.3    0.02    0.02      0
       8192           128     float    none      -1    236.2    0.03    0.03      0    235.2    0.03    0.03      0
      16384           256     float    none      -1    236.6    0.07    0.06      0    238.5    0.07    0.06      0
      32768           512     float    none      -1    237.9    0.14    0.13      0    238.8    0.14    0.13      0
      65536          1024     float    none      -1    242.3    0.27    0.25      0    239.4    0.27    0.26      0
     131072          2048     float    none      -1    263.0    0.50    0.47      0    275.1    0.48    0.45      0
     262144          4096     float    none      -1    279.2    0.94    0.88      0    269.9    0.97    0.91      0
     524288          8192     float    none      -1    273.5    1.92    1.80      0    273.5    1.92    1.80      0
    1048576         16384     float    none      -1    315.1    3.33    3.12      0    314.1    3.34    3.13      0
    2097152         32768     float    none      -1    319.2    6.57    6.16      0    311.5    6.73    6.31      0
    4194304         65536     float    none      -1    331.8   12.64   11.85      0    331.3   12.66   11.87      0
    8388608        131072     float    none      -1    356.3   23.54   22.07      0    353.8   23.71   22.23      0
   16777216        262144     float    none      -1    409.1   41.01   38.45      0    405.2   41.40   38.81      0
   33554432        524288     float    none      -1    451.4   74.34   69.69      0    447.7   74.94   70.26      0
   67108864       1048576     float    none      -1    713.4   94.07   88.19      0    713.8   94.01   88.13      0
  134217728       2097152     float    none      -1   1122.1  119.62  112.14      0   1116.3  120.23  112.72      0
  268435456       4194304     float    none      -1   1785.8  150.32  140.92      0   1769.2  151.72  142.24      0
  536870912       8388608     float    none      -1   2859.7  187.74  176.00      0   2852.6  188.20  176.44      0
 1073741824      16777216     float    none      -1   5494.1  195.44  183.22      0   5568.2  192.83  180.78      0
 2147483648      33554432     float    none      -1    10841  198.09  185.71      0    10798  198.88  186.45      0
 4294967296      67108864     float    none      -1    21453  200.21  187.70      0    21490  199.86  187.37      0
 8589934592     134217728     float    none      -1    42603  201.63  189.03      0    42670  201.31  188.73      0
# Out of bounds values : 0 OK
# Avg bus bandwidth    : 45.7587 
#
```



## **(Optional) Filestore PV の作成**

GKE から低遅延でデータにアクセスさせたい場合、データの格納場所として Filestore を利用することもできます。  
本セクションでは、Filestore CSI を利用した PV の作成を行います。  

### **1. Storage Class の作成**

GKE の Primary VPC 上に Filestore インスタンスをプロビジョニングするために、以下の Storage Class をデプロイします。  

```text
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: sc-filestore
provisioner: filestore.csi.storage.gke.io
volumeBindingMode: Immediate
allowVolumeExpansion: true
parameters:
  tier: BASIC_SSD
  network: ${PRIMARY_VPC}
EOF
```

### **2. サンプルワークロードの作成**

Filstore PV を要求する Pod をデプロイします。  

```bash
kubectl apply -f filestore-example-deployment.yaml
```

以下の内容のマニフェストを適用しています。  

```text
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
```