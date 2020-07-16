#!/bin/bash

# Tested on new VM: 
# gcloud compute instances create kind \
#   --image-family ubuntu-minimal-2004-lts \
#   --image-project ubuntu-os-cloud \
#   --machine-type e2-standard-4
# gcloud compute ssh kind

set -e pipefail

sudo apt update
sudo apt install golang -y

sudo apt install apt-transport-https ca-certificates curl software-properties-common -y
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu focal stable"
sudo apt update
sudo apt-cache policy docker-ce
sudo apt install docker-ce -y
sudo gpasswd -a $USER docker

GO111MODULE="on" go get sigs.k8s.io/kind@v0.8.1
export PATH=$PATH:~/go/bin

cat << EOF > cluster.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 32000
    hostPort: 80
EOF

sudo kind create cluster --config cluster.yaml --image kindest/node:v1.18.2

sudo curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add
sudo apt-add-repository "deb http://apt.kubernetes.io/ kubernetes-xenial main"
sudo apt install kubectl -y

kubectl apply --filename https://github.com/knative/serving/releases/download/v0.16.0/serving-crds.yaml
kubectl apply --filename https://github.com/knative/serving/releases/download/v0.16.0/serving-core.yaml

cat << EOF > kourier.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: kourier-system
  labels:
    networking.knative.dev/ingress-provider: kourier
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: config-logging
  namespace: kourier-system
  labels:
    networking.knative.dev/ingress-provider: kourier
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: config-observability
  namespace: kourier-system
  labels:
    networking.knative.dev/ingress-provider: kourier
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: config-leader-election
  namespace: kourier-system
  labels:
    networking.knative.dev/ingress-provider: kourier
data:  
  enabledComponents: kourier
---
apiVersion: v1
kind: Service
metadata:
  name: kourier
  namespace: kourier-system
  labels:
    networking.knative.dev/ingress-provider: kourier
spec:
  ports:
  - name: http2
    port: 80
    protocol: TCP
    targetPort: 8080
    nodePort: 32000  
  selector:
    app: 3scale-kourier-gateway
  type: NodePort
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: 3scale-kourier-gateway
  namespace: kourier-system
  labels:
    networking.knative.dev/ingress-provider: kourier
spec:
  selector:
    matchLabels:
      app: 3scale-kourier-gateway
  template:
    metadata:
      labels:
        app: 3scale-kourier-gateway
    spec:
      containers:
      - args:
        - --base-id
        - "1"
        - -c
        - /tmp/config/envoy-bootstrap.yaml
        command:
        - /usr/local/bin/envoy
        image: docker.io/maistra/proxyv2-ubi8:1.1.1
        imagePullPolicy: Always
        name: kourier-gateway
        ports:
        - name: http2-external
          containerPort: 8080
          protocol: TCP
        - name: http2-internal
          containerPort: 8081
          protocol: TCP
        - name: https-external
          containerPort: 8443
          protocol: TCP
        volumeMounts:
        - name: config-volume
          mountPath: /tmp/config
        lifecycle:
          preStop:
            exec:
              command: ["curl", "-X", "POST", "--unix", "/tmp/envoy.admin", "http://localhost/healthcheck/fail"]
        readinessProbe:
          httpGet:
            httpHeaders:
            - name: Host
              value: internalkourier
            path: /ready
            port: 8081
            scheme: HTTP
          initialDelaySeconds: 10
          periodSeconds: 5
      volumes:
      - name: config-volume
        configMap:
          name: kourier-bootstrap
      restartPolicy: Always
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: 3scale-kourier-control
  namespace: kourier-system
  labels:
    networking.knative.dev/ingress-provider: kourier
spec:
  replicas: 1
  selector:
    matchLabels:
      app: 3scale-kourier-control
  template:
    metadata:
      labels:
        app: 3scale-kourier-control
    spec:
      containers:
      - image: gcr.io/knative-releases/knative.dev/net-kourier/cmd/kourier@sha256:44da738a9790582443f6242666e6970134b7e31edd6984881d5d071e6d6a8186
        imagePullPolicy: Always
        name: kourier-control
        env:
        - name: CERTS_SECRET_NAMESPACE
          value: ""
        - name: CERTS_SECRET_NAME
          value: ""
        - name: SYSTEM_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        ports:
        - name: http2-xds
          containerPort: 18000
          protocol: TCP
      restartPolicy: Always
      serviceAccountName: 3scale-kourier
---
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRole
metadata:
  name: 3scale-kourier
  namespace: kourier-system
  labels:
    networking.knative.dev/ingress-provider: kourier
rules:
- apiGroups: [""]
  resources: ["pods", "endpoints", "namespaces", "services", "secrets", "configmaps"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["get", "list", "create", "update", "delete", "patch", "watch"]
- apiGroups: ["networking.internal.knative.dev"]
  resources: ["ingresses"]
  verbs: ["get", "list", "watch", "patch"]
- apiGroups: ["networking.internal.knative.dev"]
  resources: ["ingresses/status"]
  verbs: ["update"]
- apiGroups: ["apiextensions.k8s.io"]
  resources: ["customresourcedefinitions"]
  verbs: ["get", "list", "watch"]
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: 3scale-kourier
  namespace: kourier-system
  labels:
    networking.knative.dev/ingress-provider: kourier
---
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: 3scale-kourier
  labels:
    networking.knative.dev/ingress-provider: kourier
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: 3scale-kourier
subjects:
- kind: ServiceAccount
  name: 3scale-kourier
  namespace: kourier-system
---
apiVersion: v1
kind: Service
metadata:
  name: kourier-internal
  namespace: kourier-system
  labels:
    networking.knative.dev/ingress-provider: kourier
spec:
  ports:
  - name: http2
    port: 80
    protocol: TCP
    targetPort: 8081
  selector:
    app: 3scale-kourier-gateway
  type: ClusterIP
---
apiVersion: v1
kind: Service
metadata:
  name: kourier-control
  namespace: kourier-system
  labels:
    networking.knative.dev/ingress-provider: kourier
spec:
  ports:
  - name: grpc-xds
    port: 18000
    protocol: TCP
    targetPort: 18000
  selector:
    app: 3scale-kourier-control
  type: ClusterIP
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: kourier-bootstrap
  namespace: kourier-system
  labels:
    networking.knative.dev/ingress-provider: kourier
data:
  envoy-bootstrap.yaml: |
    dynamic_resources:
      ads_config:
        api_type: GRPC
        grpc_services:
          - envoy_grpc:
              cluster_name: xds_cluster
      cds_config:
        ads: {}
      lds_config:
        ads: {}
    node:
      cluster: kourier-knative
      id: 3scale-kourier-gateway
    static_resources:
      listeners:
        - name: stats_listener
          address:
            socket_address:
              address: 0.0.0.0
              port_value: 9000
          filter_chains:
            - filters:
                - name: envoy.http_connection_manager
                  config:
                    stat_prefix: stats_server
                    route_config:
                      virtual_hosts:
                        - name: admin_interface
                          domains:
                            - "*"
                          routes:
                            - match:
                                regex: '/(certs|stats(/prometheus)?|server_info|clusters|listeners|ready)?'
                                headers:
                                  - name: ':method'
                                    exact_match: GET
                              route:
                                cluster: service_stats
                    http_filters:
                      - name: envoy.router
                        config: {}
      clusters:
        - name: service_stats
          connect_timeout: 0.250s
          type: static
          load_assignment:
            cluster_name: service_stats
            endpoints:
              lb_endpoints:
                endpoint:
                  address:
                    pipe:
                      path: /tmp/envoy.admin
        - name: xds_cluster
          connect_timeout: 1s
          hosts:
            - socket_address:
                address: "kourier-control"
                port_value: 18000
          http2_protocol_options: {}
          type: STRICT_DNS
    admin:
      access_log_path: "/dev/stdout"
      address:
        pipe:
          path: /tmp/envoy.admin

---
EOF

kubectl apply -f kourier.yaml
kubectl patch configmap/config-network \
  --namespace knative-serving \
  --type merge \
  --patch '{"data":{"ingress.class":"kourier.ingress.networking.knative.dev"}}'

kubectl patch configmap/config-domain \
  --namespace knative-serving \
  --type merge \
  --patch '{"data":{"localdomain.localhost":""}}'

cat << EOF > service.yaml
apiVersion: serving.knative.dev/v1 
kind: Service
metadata:
  name: helloworld-go 
  namespace: default 
spec:
  template:
    spec:
      containers:
        - image: gcr.io/knative-samples/helloworld-go # Reference to the image of the app
          env:
            - name: TARGET # The environment variable printed out by the sample app
              value: "Knative with KinD"
EOF

kubectl apply -f service.yaml

# $: curl http://helloworld-go.default.localdomain.localhost
# Hello Knative with KinD!