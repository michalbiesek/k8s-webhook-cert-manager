#!/usr/bin/env sh

set -e

# Fully qualified name of the CSR object
csr="certificatesigningrequests"

usage() {
  cat <<EOF
Generate certificate suitable for use with any Kubernetes Mutating Webhook.
This script uses k8s' CertificateSigningRequest API to a generate a
certificate signed by k8s CA suitable for use with any Kubernetes Mutating Webhook service pod.
This requires permissions to create and approve CSR. See
https://kubernetes.io/docs/tasks/tls/managing-tls-in-a-cluster for
detailed explanation and additional instructions.
The server key/cert k8s CA cert are stored in a k8s secret.
usage: ${0} [OPTIONS]
The following flags are required.
    --service          Service name of webhook.
    --webhook          Webhook config name.
    --namespace        Namespace where webhook service and secret reside.
    --secret           Secret name for CA certificate and server certificate/key pair.
The following flags are optional.
    --webhook-kind     Webhook kind, either MutatingWebhookConfiguration or
                       ValidatingWebhookConfiguration (defaults to MutatingWebhookConfiguration)
EOF
  exit 1
}

while [ $# -gt 0 ]; do
  case ${1} in
      --service)
          service="$2"
          shift
          ;;
      --webhook)
          webhook="$2"
          shift
          ;;
      --secret)
          secret="$2"
          shift
          ;;
      --namespace)
          namespace="$2"
          shift
          ;;
      --webhook-kind)
          kind="$2"
          shift
          ;;
      *)
          usage
          ;;
  esac
  shift
done

[ -z "${service}" ] && echo "ERROR: --service flag is required" && exit 1
[ -z "${webhook}" ] && echo "ERROR: --webhook flag is required" && exit 1
[ -z "${secret}" ] && echo "ERROR: --secret flag is required" && exit 1
[ -z "${namespace}" ] && echo "ERROR: --namespace flag is required" && exit 1

fullServiceDomain="${service}.${namespace}.svc"

# THE CN has a limit of 64 characters. We could remove the namespace and svc
# and rely on the Subject Alternative Name (SAN), but there is a bug in EKS
# that discards the SAN when signing the certificates.
#
# https://github.com/awslabs/amazon-eks-ami/issues/341
if [ ${#fullServiceDomain} -gt 64 ] ; then
  echo "ERROR: common name exceeds the 64 character limit: ${fullServiceDomain}"
  exit 1
fi

if [ ! -x "$(command -v openssl)" ]; then
  echo "ERROR: openssl not found"
  exit 1
fi


tmpdir=$(mktemp -d)
echo "INFO: Creating certs in tmpdir ${tmpdir} "

cat <<EOF >> "${tmpdir}/csr.conf"
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${service}
DNS.2 = ${service}.${namespace}
DNS.3 = ${fullServiceDomain}
EOF

openssl genrsa -out "${tmpdir}/server-key.pem" 2048
openssl req -new -key "${tmpdir}/server-key.pem" -subj "/O=system:nodes/CN=system:node:${fullServiceDomain}" -out "${tmpdir}/server.csr" -config "${tmpdir}/csr.conf"

csrName=${service}.${namespace}
echo "INFO: Creating csr: ${csrName} "
set +e

# clean-up any previously created CSR for our service. Ignore errors if not present.
if kubectl get "${csr}/${csrName}"; then
  if kubectl delete "${csr}/${csrName}"; then
    echo "WARN: Previous CSR was found and removed."
  fi
fi

set -e

# create server cert/key CSR and send it to k8s api
cat <<EOF | kubectl create --validate=false -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${csrName}
spec:
  groups:
  - system:authenticated
  request: $(base64 < "${tmpdir}/server.csr" | tr -d '\n')
  signerName: kubernetes.io/kubelet-serving
  usages:
  - digital signature
  - key encipherment
  - server auth
EOF

set +e
# verify CSR has been created
while true; do
  if kubectl get "${csr}/${csrName}"; then
      break
  fi
done

set -e

# approve and fetch the signed certificate
kubectl certificate approve "${csr}/${csrName}"

set +e
# verify certificate has been signed
i=1
while [ "$i" -ne 20 ]
do
  serverCert=$(kubectl get "${csr}/${csrName}" -o jsonpath='{.status.certificate}')
  if [ "${serverCert}" != '' ]; then
      break
  fi
  sleep 3
  i=$((i + 1))
done

set -e
if [ "${serverCert}" = '' ]; then
  echo "ERROR: After approving csr ${csrName}, the signed certificate did not appear on the resource. Giving up after 1 minute." >&2
  exit 1
fi

echo "${serverCert}" | openssl base64 -d -A -out "${tmpdir}/server-cert.pem"

# create the secret with CA cert and server cert/key
kubectl create secret tls "${secret}" \
      --key="${tmpdir}/server-key.pem" \
      --cert="${tmpdir}/server-cert.pem" \
      --dry-run -o yaml |
  kubectl -n "${namespace}" apply -f -

caBundle=$(base64 < /run/secrets/kubernetes.io/serviceaccount/ca.crt  | tr -d '\n')

set +e
# Patch the webhook adding the caBundle. It uses an `add` operation to avoid errors in OpenShift because it doesn't set
# a default value of empty string like Kubernetes. Instead, it doesn't create the caBundle key.
# As the webhook is not created yet (the process should be done manually right after this job is created),
# the job will not end until the webhook is patched.
while true; do
  echo "INFO: Trying to patch webhook adding the caBundle."
  if kubectl patch "${kind:-mutatingwebhookconfiguration}" "${webhook}" --type='json' -p "[{'op': 'add', 'path': '/webhooks/0/clientConfig/caBundle', 'value':'${caBundle}'}]"; then
      break
  fi
  echo "INFO: webhook not patched. Retrying in 5s..."
  sleep 5
done
