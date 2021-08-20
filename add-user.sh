#!/usr/bin/env bash

set -euo pipefail
set -x

if ! which openssl; then
  echo "Can't find the openssl tool"
  exit 1
fi


if ! which yq; then
  echo "Can't find the yq tool"
  exit 1
fi

KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
NAME="${1:-${USER}}"
CSR_NAME="${NAME}-csr"

echo "Generating private key for user"
USER_KEY="${PWD}/${NAME}-rsa.key"
openssl genrsa -out "${USER_KEY}" 4096 2>/dev/null 1>/dev/null
echo "Wrote private key to ${USER_KEY}"

echo "Generating signing request."
OPENSSL_CNF_DATA=$(cat <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn

[dn]
CN=${NAME}
O=dev

[v3_ext]
authorityKeyIdentifier=keyid,issuer=always
basicConstraints=CA:FALSE
keyUsage=keyEncipherment,dataEncipherment
extendedKeyUsage=serverAuth,clientAuth

EOF
)
OPENSSL_CNF="${PWD}/${NAME}-openssl.cnf"
echo "${OPENSSL_CNF_DATA}" > "${OPENSSL_CNF}"

USER_CSR="${PWD}/${NAME}.csr"
openssl req -config "${OPENSSL_CNF}" -new -key "${USER_KEY}" -nodes -out "${USER_CSR}"
rm -f "${OPENSSL_CNF}"
CSR_BASE64=$(base64 < "${USER_CSR}" | tr -d '\n')

cat <<EOF | kubectl create -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${CSR_NAME} 
spec:
  request: ${CSR_BASE64}
  signerName: kubernetes.io/kube-apiserver-client
  usages:
  - client auth
EOF

echo
echo "Approving signing request."
kubectl certificate approve "${CSR_NAME}"

echo

echo "Fetching cluster CA"
CERTIFICATE_AUTHORITY_DATA=$(kubectl --insecure-skip-tls-verify -n kube-public describe configmap cluster-info | grep certificate-authority-data: | awk -F ':' '{print $2}' | xargs)

echo "Fetching cluster endpoint from ${KUBECONFIG}"
KUBECTX=$(yq e '.current-context' "${KUBECONFIG}")
CLUSTER_NAME=$(KUBECTX="${KUBECTX}" yq e ".contexts[] | select(.name == env(KUBECTX)) | .context.cluster" "${KUBECONFIG}")
CLUSTER_ENDPOINT=$(CLUSTER_NAME=${CLUSTER_NAME} yq e ".clusters[] | select(.name == env(CLUSTER_NAME)) | .cluster.server" "${KUBECONFIG}")

echo "Creating namespace for user"
USER_NS="${NAME}-ns"
kubectl create ns "${USER_NS}"

echo "Creating role for user"
cat <<EOF | kubectl create -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${NAME}-read-write
  namespace: ${USER_NS}
rules:
- apiGroups:
  - ""
  resources: ["*"]
  verbs:
  - get
  - list
  - watch
  - create
  - update
  - patch
  - delete
EOF

echo "Creating rolebinding for user"
cat <<EOF | kubectl create -f -
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: ${NAME}
  namespace: ${USER_NS}
subjects:
  - kind: User
    name: ${NAME}
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: ${NAME}-read-write
  apiGroup: rbac.authorization.k8s.io
EOF

echo "Generating kubeconfig for user ${NAME}"
CLIENT_KEY_DATA=$(base64 < "${USER_KEY}" | tr -d '\n')
CLIENT_CERTIFICATE_DATA=$(kubectl get csr "${CSR_NAME}" -o jsonpath='{.status.certificate}' | tr -d '\n')
[[ -z "${CLIENT_CERTIFICATE_DATA}" ]] && echo "Error fetching signed certificate from cluster" && exit 1
KUBECONFIG_USER="${PWD}/${NAME}.kubeconfig"
KUBECONFIG_DATA=$(cat <<EOF

apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CERTIFICATE_AUTHORITY_DATA}
    server: ${CLUSTER_ENDPOINT}
  name: ${CLUSTER_NAME}
users:
- name: ${NAME}
  user:
    client-key-data: ${CLIENT_KEY_DATA}
    client-certificate-data: ${CLIENT_CERTIFICATE_DATA}
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    user: ${NAME}
    namespace: ${USER_NS}
  name: ${NAME}-${CLUSTER_NAME}
current-context: ${NAME}-${CLUSTER_NAME}

EOF
)

echo "${KUBECONFIG_DATA}" > "${KUBECONFIG_USER}"
echo "Cleaning up"
rm -fv "${USER_KEY}"
rm -fv "${USER_CSR}"
kubectl delete csr "${CSR_NAME}"

echo "Done!"
