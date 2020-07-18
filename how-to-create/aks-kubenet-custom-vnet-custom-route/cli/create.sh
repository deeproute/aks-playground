#!/bin/bash

set -euxo pipefail

# Create AKS Cluser with Kubenet + Custom VNET + Custom Route Table
# https://docs.microsoft.com/en-us/azure/aks/configure-kubenet
# Please install jq before running this (required to extract the SP appId & password):
# sudo apt update
# sudo apt install jq

# Resources Location
az configure --defaults location=westeurope

# Network Config
VNET_RG=vnet-custom
VNET_NAME=aks-custom-vnet
VNET_ADDR_PREFIX=192.168.0.0/16
VNET_SUBNET_NAME=custom-vnet-subnet
VNET_SUBNET_ADDR_PREFIX=192.168.1.0/24
VNET_SUBNET_ROUTETABLE_NAME=custom-subnet-routetable

# AKS Config
AKS_RG=aks-custom-vnet
AKS_NAME=aks-custom-vnet
AKS_K8S_VERSION=1.18.4
AKS_NODECOUNT=3
AKS_NET_PLUGIN=kubenet
AKS_SVC_CIDR=10.0.0.0/16 # Private IP Range for the internal services like ClusterIP,NodePort,LoadBalancer...
AKS_DNS_SVC_IP=10.0.0.10 # DNS IP
AKS_POD_CIDR=10.244.0.0/16 # POD Network IP Range

# Create Custom VNET
az group create --name $VNET_RG

az network vnet create \
    --resource-group $VNET_RG \
    --name $VNET_NAME \
    --address-prefixes $VNET_ADDR_PREFIX \
    --subnet-name $VNET_SUBNET_NAME \
    --subnet-prefix $VNET_SUBNET_ADDR_PREFIX

VNET_ID=$(az network vnet show --resource-group $VNET_RG --name $VNET_NAME --query id -o tsv)
SUBNET_ID=$(az network vnet subnet show --resource-group $VNET_RG --vnet-name $VNET_NAME --name $VNET_SUBNET_NAME --query id -o tsv)

# Create and associate a custom route table to the subnet
ROUTETABLE_ID=$(az network route-table create -g $VNET_RG -n $VNET_SUBNET_ROUTETABLE_NAME --query id -o tsv)
az network vnet subnet update -g $VNET_RG --vnet-name $VNET_NAME -n $VNET_SUBNET_NAME --route-table $VNET_SUBNET_ROUTETABLE_NAME

# Need to add custom route table so it goes outside the MC_ resource group

# Create AKS Service Principal
AAD_SP=$(az ad sp create-for-rbac --skip-assignment)

AAD_SP_APPID=$(echo $AAD_SP | jq -r '.appId')
AAD_SP_PASS=$(echo $AAD_SP | jq -r '.password')

sleep 5

# Assign this roles so the cluster can update the route table
az role assignment create --assignee $AAD_SP_APPID --scope $SUBNET_ID --role "Network Contributor"
az role assignment create --assignee $AAD_SP_APPID --scope $ROUTETABLE_ID --role "Network Contributor"

# Create the actual AKS Cluster with Kubenet, custom VNET and Service Principal with right permissions 
az group create --name $AKS_RG

az aks create \
    --resource-group $AKS_RG \
    --name $AKS_NAME \
    --kubernetes-version $AKS_K8S_VERSION \
    --node-count $AKS_NODECOUNT \
    --network-plugin $AKS_NET_PLUGIN \
    --service-cidr $AKS_SVC_CIDR \
    --dns-service-ip $AKS_DNS_SVC_IP \
    --pod-cidr $AKS_POD_CIDR \
    --docker-bridge-address 172.17.0.1/16 \
    --vnet-subnet-id $SUBNET_ID \
    --service-principal $AAD_SP_APPID \
    --client-secret $AAD_SP_PASS