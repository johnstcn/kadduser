# Kubernetes add user

This is a quick and dirty script to create a kubernetes user.

## Usage

```shell
./add-user.sh $USERNAME
```

If `$USERNAME` is omitted, it defaults to the name of the current user.

The script does the following:

* Creates a 4096-bit RSA key for the user
* Creates and approves a CSR for the user
* Creates a namespace for the user (defaults to `${USER}-ns`)
* Creates a role+rolebinding for the user giving read-write access to all resources in the above namespace
* Creates a kubeconfig for the user, with all certificates embedded
