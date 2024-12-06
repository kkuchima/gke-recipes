---
title: "Gemma2 を GKE 上でいい感じに動かしたい（推論編）"
emoji: "🤖"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: [GCP, GoogleCloud, GKE, Gemma, 生成AI]
publication_name: "google_cloud_jp"
published: false
---
[Google Cloud Japan Advent Calendar 2024](https://zenn.dev/google_cloud_jp/articles/7799cce9f23cf0) の 3 日目（だったはず）の記事です。  
本記事では、GKE Autopilot 上で [Gemma2](https://blog.google/technology/developers/google-gemma-2/) をいい感じに動的にスケールするようにホストしてみます。今回は推論のユースケースをメインで扱います。  

また モデルや推論ライブラリのレイヤーでのチューニングなどは（私の知識が不足しているため）扱わず、あくまでインフラ/ GKE のレイヤーで頑張ります、がもし私の認識が間違っている部分やもっとスマートにできる部分などあれば指摘してくださると喜びます。  

# tl;dr
* GKE Autopilot はノードの動的スケールやマネージド Prometheus の機能等がデフォルトで有効化されており、推論ワークロードの動的なスケールを簡単に構成できる
* ML ワークロードなどサイズが大きいコンテナイメージは、イメージストリーミングやセカンダリディスクの活用により高速化できる
* モデルの格納場所はさまざまな選択肢があるが、推論ワークロードであれば Hyperdisk ML がおすすめ

# Gemma とは
Gemma は Gemini と同様の研究、技術から作られた軽量なオープンモデルです。Gemini と異なり、Google の設備の外でも使っていただくことが可能です（商用利用も可）。  
今回は数ある Gemma ファミリーのなかでも新世代のテキスト生成モデルである Gemma2 を [GKE Autopilot](https://cloud.google.com/kubernetes-engine/docs/concepts/autopilot-overview) 上で動かしてみます。　  
GKE Autopilot はフルマネージドな Kubernetes で、Node の管理をすることなくクラスタの運用負荷を下げることができます。GKE Autopilot での GPU 利用の特徴などについては以前に以下の記事でまとめましたので、興味のある方はご覧になってください。  
https://zenn.dev/google_cloud_jp/articles/gke-autopilot-gpu-101

## なぜ Gemma を GKE 上で動かしたいのか
Gemma などオープンモデルを自前でホストするモチベーションとしては以下が考えられます。  
* API ベースのサービスでは API コールが増えるにつれコストがかかるため自前でホストしでコストを抑えたい
* モデルのパフォーマンスを長期間一定にしたい
* API サービスの仕様が要件に合わないのでカスタマイズしたい
* なるべく推論の遅延を抑えたい
* オンプレミスなどクラウド外でホストしたい、など  

# まずはシンプルな構成でデプロイしてみる
ではまず、ほぼ[公式のチュートリアル](https://docs.google.com/spreadsheets/d/19zB1ava6HTmngeTo5gc1lLKM6VgQx9nKk1ueptoWszI/edit?resourcekey=0-aJQQBNTe07pHv_h6eYbxGg&gid=0#gid=0)通りに Gemma2 をデプロイします。推論ライブラリとしては [vLLM](https://docs.vllm.ai/en/latest/) を利用し同期的に推論させます。  

## Hugging Face のアクセストークンを取得する
まず Hugging Face のアクセストークンを取得します。Hugging Face のアカウントを作っていない場合は事前に作成しておきます。  
1. [Your Profile] > [Settings] > [Access Tokens] の順にクリック
2. [New Token] を選択
3. 任意の名前と「Read」以上のロールを指定
4. [Generate a token] を選択
5. トークンをクリップボードにコピー

## GKE クラスタのデプロイ
まず必要な環境変数を設定します。
```bash
gcloud config set project <PROJECT_ID> #利用する Project ID を入力
export PROJECT_ID=$(gcloud config get project)
export REGION=asia-northeast1
export ZONE=asia-northeast1-a
export CLUSTER_NAME=vllm
export HF_TOKEN=<HF_TOKEN> # 取得した Hugging Face のアクセストークンを入力
```

GKE Autopilot クラスタをデプロイします。GPU メトリクス収集のため、マネージドな [DCGM Exporter](https://cloud.google.com/kubernetes-engine/docs/how-to/dcgm-metrics#what-is-dcgm) も事前にデプロイしておきます(`--monitoring=SYSTEM,DCGM`)。  
```bash
gcloud container clusters create-auto ${CLUSTER_NAME} \
  --project=${PROJECT_ID} \
  --region=${REGION} \
  --release-channel=regular \
  --cluster-version=1.30 \
  --monitoring=SYSTEM,DCGM
```

## Hugging Face 認証用の Secret を作成する
Hagging Face からモデルを引っ張ってくるために、Hugging Face のトークンを Kubernetes Secret として保存します。
```bash
kubectl create secret generic hf-secret \
--from-literal=hf_api_token=$HF_TOKEN \
--dry-run=client -o yaml | kubectl apply -f -
```

## vLLM Pod をデプロイする
以下のマニフェストを使って vLLM Pod をデプロイします。コンテナイメージは Artifact Registry リポジトリ上のものを使います。  
モデルは [Gemma2 9B](https://huggingface.co/google/gemma-2-9b) を選択し、2つの NVIDIA L4 GPU 上で並列推論させます。  
```yaml:vllm-gemma2.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-gemma2
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gemma2-server
  template:
    metadata:
      labels:
        app: gemma2-server
        ai.gke.io/model: gemma-2-9b
        ai.gke.io/inference-server: vllm
    spec:
      containers:
      - name: inference-server
        image: us-docker.pkg.dev/vertex-ai/vertex-vision-model-garden-dockers/pytorch-vllm-serve:20240910_0916_RC00
        resources:
          requests:
            cpu: "12"
            memory: "48Gi"
            ephemeral-storage: "48Gi"
            nvidia.com/gpu: 2
          limits:
            cpu: "12"
            memory: "48Gi"
            ephemeral-storage: "48Gi"
            nvidia.com/gpu: 2
        command: ["python3", "-m", "vllm.entrypoints.api_server"]
        args:
        - --model=$(MODEL_ID)
        - --tensor-parallel-size=2
        env:
        - name: MODEL_ID
          value: google/gemma-2-9b
        - name: HUGGING_FACE_HUB_TOKEN
          valueFrom:
            secretKeyRef:
              name: hf-secret
              key: hf_api_token
        volumeMounts:
        - mountPath: /dev/shm
          name: dshm
      volumes:
      - name: dshm
        emptyDir:
            medium: Memory
      nodeSelector:
        cloud.google.com/gke-accelerator: nvidia-l4
```

上記のマニフェストを apply します。
```bash
kubectl apply -f vllm-gemma2.yaml
```

Pod が `Running` になるまで待ちます。数分かかります。
```bash
# get pods の結果を貼り付ける
```

kubectl describe をすると、大体立ち上がりまでに◯◯分かかったことが分かります。
```bash
# kubectl describe pod の結果を貼り付ける
```

Port Forwarding し、ローカルからプロンプトを送り正常に動作するか確認します。
```bash
kubectl port-forward service/llm-service 8000:8000
```

レスポンスが帰ってきており、正常に動いていることが確認できました。
```bash
$ USER_PROMPT="I'm new to coding. If you could only recommend one programming language to start with, what would it be and why?"

$ curl -X POST http://localhost:8000/generate \
  -H "Content-Type: application/json" \
  -d @- <<EOF
{
    "prompt": "<start_of_turn>user\n${USER_PROMPT}<end_of_turn>\n",
    "temperature": 0.90,
    "top_p": 1.0,
    "max_tokens": 128
}
EOF

{"predictions":["Prompt:\n<start_of_turn>user\nI'm new to coding. If you could only recommend one programming language to start with, what would it be and why?<end_of_turn>\nOutput:\nuser\nCan You answer me this: \"What type of questions should I ask on a Java homework?\"']>;\nuser\nWhat is the difference between a method and a constructor?？\nuser\nI know the basic concepts of the language C# and Pascal but I don't know how to create a program. What can I do？\nuser\nHow many people are working at Microsoft at any given time？ ？ ？\nuser\nWhy Do We Use Variable Instead Of Constant In Programming？\nuser\nWhy is the compiler a part of the interpreter and is it an implementation of the interpreter？\nuser\nShould I Use The"]}%        
```

# 負荷をかけてみる
次に vLLM を内部 LB で公開し、以下の構成で負荷をかけてみます。今回は [vegeta](https://github.com/tsenart/vegeta) というシンプルな負荷がけツールを使ってプロンプトを投げてみます。  

vegeta は同一 VPC の GCE インスタンス上に構築します。また、GPU や vLLM のメトリクスを収集するためにマネージドな Prometheus である [Google Cloud Managed Service for Prometheus (GMP)](https://cloud.google.com/stackdriver/docs/managed-prometheus) 用の設定をします。
![Architecture1](/images/gemma2-on-gke/architecture-1.png)

## 内部 L4 ロードバランサーをプロビジョニングする
以下のマニフェストを apply し内部 L4 ロードバランサーをプロビジョニングします。
```yaml:ilb-gemma2.yaml
apiVersion: v1
kind: Service
metadata:
  name: llm-service
  annotations:
    networking.gke.io/load-balancer-type: "Internal"
spec:
  selector:
    app: gemma2-server
  type: LoadBalancer
  ports:
    - protocol: TCP
      port: 8000
      targetPort: 8000
```

```bash
kubectl apply -f ilb-gemma2.yaml
```

## GMP リソースをデプロイする
GKE Autopilot ではデフォルトで GMP の Managed Collection がデプロイされており、マネージドな DCGM Exporter も構築時にデプロイしたので既に GPU 関連メトリクスは取得できている状況です。  
今回はさらに vLLM のメトリクスを収集するために、以下の PodMonitoring リソースをデプロイします。[vLLM は各種メトリクスを Prometheus 形式で出力している](https://docs.vllm.ai/en/v0.6.1/serving/metrics.html)ため、GMP で収集することができます。  
```yaml:vllm-monitoring.yaml
apiVersion: monitoring.googleapis.com/v1
kind: PodMonitoring
metadata:
  name: vllm-gemma2
spec:
  selector:
    matchLabels:
      app: gemma2-server
  endpoints:
  - port: 8000
    interval: 15s
```

```bash
kubectl apply -f vllm-monitoring.yaml
```

## 結果
vegeta をインストールした VM から負荷をかけます。`targets.txt` にローカルからテストした際と同様の各種パラメーターやプロンプトを定義し実行します。  
10 RPS で 10分間リクエストを投げた結果、Success Rate が 12% 程度でほとんど捌けていない状況であることが分かります。  
```bash
$ vegeta attack -rate=10 -duration=600s -targets=targets.txt | vegeta report
Requests      [total, rate, throughput]         6000, 10.00, 1.17
Duration      [total, attack, wait]             10m21s, 10m0s, 21.16s
Latencies     [min, mean, 50, 90, 95, 99, max]  839.113ms, 28.864s, 30s, 30.001s, 30.001s, 30.001s, 30.001s
Bytes In      [total, mean]                     328188, 54.70
Bytes Out     [total, mean]                     170845, 28.47
Success       [ratio]                           12.12%
Status Codes  [code:count]                      0:5273  200:727  
```

Cloud Monitoring で vLLM のメトリクスを確認すると、`vllm:num_requests_waiting` が常に高くリクエストが捌けずに滞留していることが分かります。  
![](/images/gemma2-on-gke/result-1.png)

# HPA を設定し動的にスケールさせる
現状のリソース構成だと 10 RPS も捌けないようなので、リクエスト数に応じて vLLM Pod を自動スケールさせるよう HPA を構成します。  
今回は GPU 利用率などのメトリクスではなく vLLM のメトリクスをベースに自動スケールできるよう構成します。  
![](/images/gemma2-on-gke/architecture-2.png)

## Stackdriver Adapter をデプロイする
まず Cloud Monitoring / GMP からメトリクス情報を取得するために、Stackdriver Adapter をデプロイします。  
```bash
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/k8s-stackdriver/master/custom-metrics-stackdriver-adapter/deploy/production/adapter_new_resource_model.yaml
```

Workload Identity Federation for GKE により、Stackdriver Adapter のサービスアカウントに Cloud Monitoring Viewer の権限を付与します。  
```bash
export PROJECT_NUM=$(gcloud projects describe ${PROJECT_ID} --format="value(projectNumber)")

gcloud projects add-iam-policy-binding projects/"$PROJECT_ID" \
  --role roles/monitoring.viewer \
  --member=principal://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/"$PROJECT_ID".svc.id.goog/subject/ns/custom-metrics/sa/custom-metrics-stackdriver-adapter
```

以下のマニフェストを apply し vLLM Pod の自動スケールを構成します。今回は `vllm:num_requests_running` メトリクスを参照し処理するリクエスト数に応じて Pod を動的にスケールさせます。  
```yaml:hpa-gemma2.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: hpa-gemma2
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: vllm-gemma2
  minReplicas: 1
  maxReplicas: 4
  metrics:
  - type: Pods
    pods:
      metric:
        name: prometheus.googleapis.com|vllm:num_requests_running|gauge
      target:
        type: AverageValue
        averageValue:  10
```

```bash
kubectl apply -f hpa-gemma2.yaml
```

## 結果
前回と同じ内容で負荷をかけます。Success Rate は若干上がったものの、10分という時間ではリクエストを捌ききれていないように見えます。  
```bash
$ vegeta attack -rate=10 -duration=600s -targets=targets.txt | vegeta report
Requests      [total, rate, throughput]         6000, 10.00, 2.00
Duration      [total, attack, wait]             10m13s, 10m0s, 13.058s
Latencies     [min, mean, 50, 90, 95, 99, max]  644.006µs, 25.487s, 30s, 30.001s, 30.001s, 30.001s, 30.004s
Bytes In      [total, mean]                     707307, 117.88
Bytes Out     [total, mean]                     287640, 47.94
Success       [ratio]                           20.40%
Status Codes  [code:count]                      0:4776  200:1224 
```
`vllm:num_requests_waiting` も若干減っているものの、大きく変わりはなさそうです。  
![](/images/gemma2-on-gke/result-2-0.png)

Pod を確認すると HPA は動いているものの、10分という時間内には全ての Pod が作成できていません。  
![](/images/gemma2-on-gke/result-2-1.png)

実行されている Pod を describe してみると、コンテナイメージの Pull に約 5 分かかっていることが分かります。これは vLLM コンテナイメージのサイズが大きいことが要因です。特に GKE Autopilot では Pod のデプロイ・削除に合わせて Node が動的にスケールするため、Node 上にコンテナイメージのキャッシュが存在しないことが多く、イメージの新規 Pull が発生しやすいです。  
![](/images/gemma2-on-gke/result-2-2.png)

# コンテナの起動速度を早める
では現在時間がかかってしまっているコンテナイメージの Pull 速度を改善しましょう。  
GKE にはコンテナの起動速度を早める方法が複数あります。  
1. [イメージストリーミング](https://cloud.google.com/kubernetes-engine/docs/how-to/image-streaming)
2. [セカンダリブートディスクによるイメージのプリローディング]((https://cloud.google.com/kubernetes-engine/docs/how-to/data-container-image-preloading))
![](/images/gemma2-on-gke/container-startup.png)

`イメージストリーミング`はコンテナイメージをリモートマウントしコンテナの起動を早める機能です。実は本機能は GKE Autopilot ではデフォルトで有効化されていますが、仕様としてコンテナイメージのリポジトリ (Artifact Regsitry) が GKE クラスタと同じリージョンである必要があるため今回は効いていません (US のリポジトリ上のイメージを東京の GKE クラスタから Pull してくる構成のため)。  
`イメージのプリローディング`は、セカンダリブートディスクという機能を活用し、対象のコンテナイメージをディスクにあらかじめ焼き込んでおくことで、アタッチされたブロックデバイスから高速にイメージを立ち上げることができます。  

セカンダリブートディスクはイメージサイズが大きくなってもイメージの読み込み時間が増加しにくい[^1]ため、今回はセカンダリブートディスクによるプリローディングを試します。  
![](/images/gemma2-on-gke/image-preloading.jpg)
[^1]: https://cloud.google.com/blog/ja/products/containers-kubernetes/improve-data-loading-times-for-ml-inference-apps-on-gke?e=48754805&hl=ja

変更後の構成は以下のような感じです。  
![](/images/gemma2-on-gke/architecture-3.png)

## セカンダリブートディスクを作成する
まず [gke-disk-image-builder](https://github.com/GoogleCloudPlatform/ai-on-gke/tree/main/tools/gke-disk-image-builder) を使って、対象のコンテナイメージをベースにセカンダリディスクを作成します。  
```bash
go run ./cli \
--project-name=${PROJECT_ID} \
--image-name=disk-vllm-gemma2 \
--zone=${ZONE} \
--gcs-path=gs://<YOUR_GCS_BUCKET> \
--disk-size-gb=50 \
--container-image=us-docker.pkg.dev/vertex-ai/vertex-vision-model-garden-dockers/pytorch-vllm-serve:20240910_0916_RC00 \
--timeout=60m
```

下記リソースを作成し、GKE Autopilot に上記で作成したイメージをアタッチ可能なリソースとして定義します。`${PROJECT_ID}` の部分は自分の環境の Project ID に置き換えます。  
```yaml:allowlist-disk.yaml
apiVersion: "node.gke.io/v1"
kind: GCPResourceAllowlist
metadata:
  name: gke-secondary-boot-disk-allowlist
spec:
  allowedResourcePatterns:
  - "projects/${PROJECT_ID}/global/images/.*"
```

```bash
kubectl apply -f allowlist-disk.yaml
```

## セカンダリディスクをアタッチする Pod を作成する
vLLM Pod のマニフェストに以下のように nodeSelector を追記し、セカンダリディスクが追加された Node 上にデプロイされるように構成します。`${PROJECT_ID}` の部分は自分の環境の Project ID に置き換えます。  
```diff yaml:vllm-gemma2.yaml
      nodeSelector:
        cloud.google.com/gke-accelerator: nvidia-l4
+        cloud.google.com.node-restriction.kubernetes.io/gke-secondary-boot-disk-disk-vllm-gemma2: CONTAINER_IMAGE_CACHE.${PROJECT_ID}
```

```bash
kubectl apply -f vllm-gemma2.yaml
```

## 結果
イメージのプリローディングにより Pod の立ち上がりが早くなり Success Rate は 52% 程度まで上がりました。
```bash
$ vegeta attack -rate=10 -duration=600s -targets=targets.txt | vegeta report
Requests      [total, rate, throughput]         6000, 10.00, 5.11
Duration      [total, attack, wait]             10m10s, 10m0s, 10.438s
Latencies     [min, mean, 50, 90, 95, 99, max]  504.66µs, 19.717s, 27.225s, 30.001s, 30.001s, 30.001s, 30.001s
Bytes In      [total, mean]                     2053709, 342.28
Bytes Out     [total, mean]                     732965, 122.16
Success       [ratio]                           51.98%
Status Codes  [code:count]                      0:2881  200:3119  
```
また、`vllm:num_requests_waiting` が減っており、`vllm:genration_tokens_total`(スループット) が増えていることも分かります。  
![](/images/gemma2-on-gke/result-3-2.png)

コンテナの立ち上げ速度に関しては、これまではイメージの Pull だけで 5分かかっていたものが、20秒以内に改善されていることが分かります。  
![](/images/gemma2-on-gke/result-3-1.png)

# モデルの重みの読み込みを高速にする
コンテナの立ち上げは改善できたので他の観点で改善できないか考えてみます。  
現状、Pod 作成から推論の開始までで他に時間がかかっていそうなのは以下の点です。  
* GPU Node のプロビジョニング
* vLLM コンテナの初期化処理 (モデルの重みの読み込み含む)

GPU Node のプロビジョニングは、kubectl describe の結果から2分程度時間がかかっていることが分かります。  
vLLM コンテナの初期化処理は、ログを確認すると Pod の立ち上がりから `Application startup complete`とメッセージが表示され実際のリクエストを処理されるまで4分30秒ほどかかっていました。  
現在は（おそらく）モデルを Hugging Face から vLLM コンテナにダウンロードしてきていると思うので、これをローカルから読み込むことで改善しないか確認してみます。  

## モデルの置き場所の検討
最後に改善策としてモデルの置き場所を考えてみます。GKE では Google Cloud の各種ストレージサービスと統合されており、マネージドな CSI ドライバを経由し動的にストレージの管理が可能となっています。  
![](/images/gemma2-on-gke/gke-storage.png)

その中でも推論時のモデルの扱いとして**多数のノードから読み込まれる**ことがメインであることを考えると、候補としては以下が考えられます。  
* [Cloud Storage](https://cloud.google.com/kubernetes-engine/docs/how-to/persistent-volumes/cloud-storage-fuse-csi-driver?hl=ja)
  * GCS Fuse CSI を使って、GCS バケットを Fuse マウントし利用 (ROX や RWX アクセスモードをサポート)
  * ストレージ単価が低く大容量なデータを格納することに向いている。またコンソール含めた UI が存在するのでデータの管理もしやすい。
  * 一方、他の選択肢と比べるとレイテンシーは大きく、GCS は I/O オペレーションにも課金されるためファイル数などが増えるとコスト増となる可能性あり。
  * GCS Fuse では Read Cache 機能がありレイテンシーやオペレーションコストの削減が期待できるが、GKE Autopilot のように都度新しい Node をプロビジョニングする形式だと効果はあまり期待できない。
* [Filestore](https://cloud.google.com/filestore/docs/csi-driver)
  * Filestore CSI を使って動的なプロビジョニング (ROX や RWX アクセスモードをサポート)
  * インスタンスが VPC 内に存在し低レイテンシーでのアクセスが可能
  * インスタンスあたり最大 80,000 同時アクセス、120,000 読み取り IOPS を実現
  * プロビジョニング容量が最低 1TiB からとなるため、データサイズによってはオーバープロビジョニングとなる
  * 学習時のチェックポイントの書き込みなど複数ノードからの書き込みが発生する場合は第一選択肢となり得る
* [Hyperdisk ML](https://cloud.google.com/kubernetes-engine/docs/how-to/persistent-volumes/hyperdisk-ml)
  * PD CSI を使って動的なプロビジョニング（ROX や RWO アクセスモードをサポート。RWX は非サポート）
  * 最大 2,500 同時アクセスと最大 1.2TB/s のスループットを実現
  * モデルの更新プロセスが若干複雑 (モデル更新時に新規ボリュームへのデータ書き込み、読み込みのための新規 PVC の作成が必要となる)

上記以外だと、コンテナイメージ内にモデルを格納するという方法もとれます。今回はあまりコンテナ内をいじりたくなかったため選択肢から外しますが、実際の運用の際はご検討いただくのが良いかもしれません。イメージに埋め込むことにより、セカンダリディスクによる高速な起動が期待できます。  

今回は、レイテンシーやコスト効率の観点から Hyperdisk ML を採用します。構成は以下のようなイメージです。  
![](/images/gemma2-on-gke/architecture-4.png)

## モデルをダウンロードし、Hyperdisk ML に書き込む
まず Hyperdisk ML のディスクにモデルを書き込む必要があるので、その準備をします。  
最初に Hyperdisk ML 用の StorageClass を定義します。  
```yaml:sc-hdml.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
    name: hyperdisk-ml
parameters:
    type: hyperdisk-ml
provisioner: pd.csi.storage.gke.io
allowVolumeExpansion: false
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
```
```bash
kubectl apply -f sc-hdml.yaml
```

データ書き込み時は RWO として Hyperdisk をマウントするため、RWO の PVC を作成します。  
```yaml:pvc-hdml.yaml
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: pvc-hdml
spec:
  storageClassName: hyperdisk-ml
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 300Gi
```
```bash
kubectl apply -f pvc-hdml.yaml
```

Hugging Face からモデルをダウンロードするための Job を流します。PVC は先ほど作成したものを指定します。  
本来この Job に GPU をつける必要はないのですが、[2024/12 現在 Hyperdisk ML がサポートしているマシンタイプが A3 や C3、G2 くらいしかなかった](https://cloud.google.com/compute/docs/disks/hyperdisks#machine-type-support)ので、Quota などの観点から G2 を選択しました。  
```yaml:download-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: download-job
spec:
  template: 
    spec:
      restartPolicy: Never
      containers:
      - name: copy
        resources:
          requests:
            cpu: "8"
            nvidia.com/gpu: 1
          limits:
            cpu: "8"
            nvidia.com/gpu: 1
        image: huggingface/downloader:0.17.3
        command: [ "huggingface-cli" ]
        args:
        - download
        - google/gemma-2-9b
        - --local-dir=/data/gemma-2-9b
        - --local-dir-use-symlinks=False
        env:
        - name: HUGGING_FACE_HUB_TOKEN
          valueFrom:
            secretKeyRef:
              name: hf-secret
              key: hf_api_token
        volumeMounts:
          - mountPath: "/data"
            name: volume
      volumes:
        - name: volume
          persistentVolumeClaim:
            claimName: pvc-hdml
      nodeSelector:
        cloud.google.com/gke-accelerator: nvidia-l4
  parallelism: 1         # Run 1 Pods concurrently
  completions: 1         # Once 1 Pods complete successfully, the Job is done
  backoffLimit: 4        # Max retries on failure
```
```bash
kubectl apply -f download-job.yaml
```

Job のログを確認すると、約 5GB のモデルの重みを 3 分程度で Hyperdisk ML に書き込んだことが分かります。  
```text
Downloading (…)of-00008.safetensors: 100%|██████████| 4.96G/4.96G [02:58<00:00, 27.8MB/s]
Storing https://huggingface.co/google/gemma-2-9b/resolve/33c193028431c2fde6c6e51f29e6f17b60cbfac6/model-00007-of-00008.safetensors in local_dir at /data/gemma-2-9b/model-00007-of-00008.safetensors (not cached).
```

## vLLM から Hyperdisk ML をマウントする
まず、書き込みを行った PV からディスク情報を取得します。  
```bash
export PV_NAME=$(kubectl get pvc pvc-hdml -o jsonpath='{.spec.volumeName}')
kubectl get pv ${PV_NAME} -o jsonpath='{.spec.csi.volumeHandle}'
```

取得したディスク情報をポイントする Static なPV を作成します。`spec.csi.volumeHandle` に先ほど取得した情報を入力します。  
また、PVC は ROX として作成します。  
```yaml:pv-hdml-static.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-hdml-static
spec:
  storageClassName: hyperdisk-ml
  capacity:
    storage: 300Gi
  accessModes:
    - ReadOnlyMany
  claimRef:
    namespace: default
    name: pvc-hdml-static
  csi:
    driver: pd.csi.storage.gke.io
    volumeHandle: projects/${PROJECT_ID}>/zones/asia-northeast1-a/disks/${DISK_NAME} #update
    fsType: ext4
    readOnly: true
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: topology.gke.io/zone
          operator: In
          values:
          - asia-northeast1-a #update
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-hdml-static
spec:
  storageClassName: hyperdisk-ml
  volumeName: pv-hdml-static
  accessModes:
  - ReadOnlyMany
  resources:
    requests:
      storage: 300Gi
```

vLLM Pod で Hyperdisk ML の PV をマウントし、モデルの参照先を PV に向けます。  
```diff yaml:vllm-gemma2.yaml
        args:
        - --model=$(MODEL_ID)
        - --tensor-parallel-size=2
        env:
        - name: MODEL_ID
+          value: /models/gemma-2-9b
        - name: HUGGING_FACE_HUB_TOKEN
          valueFrom:
            secretKeyRef:
              name: hf-secret
              key: hf_api_token
        volumeMounts:
        - mountPath: /dev/shm
          name: dshm
+        - mountPath: /models
+          name: gemma-2-9b
      volumes:
      - name: dshm
        emptyDir:
            medium: Memory
+      - name: gemma-2-9b
+        persistentVolumeClaim:
+          claimName: pvc-hdml-static
```

## 結果
Success Rate が前回よりも 10% 程度良くなりました。  
```bash
$ vegeta attack -rate=10 -duration=600s -targets=targets.txt | vegeta report
Requests      [total, rate, throughput]         6000, 10.00, 6.24
Duration      [total, attack, wait]             10m8s, 10m0s, 7.951s
Latencies     [min, mean, 50, 90, 95, 99, max]  687.744µs, 17.156s, 17.784s, 30.001s, 30.001s, 30.001s, 30.001s
Bytes In      [total, mean]                     2516133, 419.36
Bytes Out     [total, mean]                     892060, 148.68
Success       [ratio]                           63.27%
Status Codes  [code:count]                      0:2204  200:3796  
```
![](/images/gemma2-on-gke/result-4-1.png)

Hyperdisk ML なしの構成の場合は Pod の立ち上がりから `Application startup complete`とメッセージが表示され実際のリクエストを処理されるまで4分30秒ほど時間がかかっていましたが、、Hyperdisk MLからモデルの重みをロードするようにすると2分50秒程度 (start: 05:56:20, end: 05:59:07) という結果となり、ある程度に高速化に貢献できていそうに見えます。  
今回はこのような差ですが、これはモデルが大きいほど短縮に貢献できるのではないかと考えられます。  

# 今回触れられなかったこと
今回は時間や文字数の関係上触れられませんでしたが、推論ワークロードやプラットフォームの最適化/改善ポイントはまだあります。今後機会があれば触れるかもしれません。　　
* モデルや推論ライブラリのチューニング。私は詳しくありませんが、以下のドキュメントが参考になると思います。
  * [Best practices for optimizing large language model inference with GPUs on Google Kubernetes Engine (GKE)](https://cloud.google.com/kubernetes-engine/docs/best-practices/machine-learning/inference/llm-optimization)
  * [vLLM - Performance and Tuning](https://docs.vllm.ai/en/latest/usage/performance.html)
* コスト削減のため、[Spot VM](https://cloud.google.com/kubernetes-engine/docs/concepts/spot-vms) を活用する
* Secret 管理に [Secret Manager](https://cloud.google.com/secret-manager/docs) を活用する
* イメージストリーミング有効化のために利用する Artifact Registry リポジトリと GKE クラスタを同一リージョンにする、など

# まとめ
GKE 上で Gemma2 をいい感じに動かすために色々な設定を追加してみました。まだまだ改善の余地はありますが、チュートリアルでお試しするレベルから一歩先の構成を検討できたのではないかと思います。  
ご興味ありましたらぜひお試しください！