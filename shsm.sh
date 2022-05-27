#!/bin/bash

# May need to convert id_rsa with:
#  `cp ~/.ssh/id_rsa ~/.ssh/id_rsa.rsa; ssk-keygen -p -m pem -f ~/.ssh/id_rsa.rsa`

SUBCOMMAND=$1
shift

if [ "$SUBCOMMAND" = "phase" ]; then
  SUBCOMMAND=$1
  shift
  if [ "$SUBCOMMAND" = "lock" -a "$#" -eq "1" ]; then
    phase=$1
    shift

    # Generate a new key.
    export aeskey=$(openssl rand 32)
    echo ${aeskey} | openssl pkeyutl -encrypt -pubin -inkey <(ssh-keygen -e -m PKCS8 -f ~/.ssh/id_rsa.pub) -out phases/$phase/keys/$phase.key
    
    # Encrypt all of the secrets.
    for envvar in $(ls -1 phases/$phase/insecure); do 
      openssl enc -aes-256-cbc -base64 -A -in phases/$phase/insecure/$envvar -out phases/$phase/secure/$envvar -pass env:aeskey
    done

    # Remove the insecure versions (kept in /tmp).
    rm -rf $(realpath phases/$phase/insecure)
    rm -f phases/$phase/insecure
    exit 0
  fi

  if [ "$SUBCOMMAND" = "unlock" -a "$#" -eq "1" ]; then
    phase=$1
    shift
    
    # Setup volatile store for our insecure secrets.
    real_insecure=$(mktemp -d)
    ln -s $real_insecure phases/$phase/insecure

    # Decrypt the AES key
    export aeskey=$(openssl pkeyutl -decrypt -inkey ~/.ssh/id_rsa.rsa -in phases/$phase/keys/$phase.key)
    for envvar in $(ls -1 phases/$phase/secure); do 
      openssl enc -d -aes-256-cbc -base64 -A -in phases/$phase/secure/$envvar -out phases/$phase/insecure/$envvar -pass env:aeskey
    done
    exit 0
  fi
  exit 1
fi

if [ "$SUBCOMMAND" = "bundle" ]; then
  SUBCOMMAND=$1
  shift
  if [ "$SUBCOMMAND" = "build" -a "$#" -eq "1" ]; then
    BUNDLE=$1
    shift
    
    # Build bundle string.
    newline=$'\n'
    bundle_data="export${newline}"
    saved_IFS="${IFS}"

    # Since we allow bundles to mix/match from different phases we track each password in an associative array.
    # This associative array is a bash-ism and breaks a lot of compatibility. Perhaps we could cache these in
    # /tmp with the insecure values for compatibility?
    declare -A aesKeys
    for phase in $(cat bundles/$BUNDLE/bundle.conf | cut -d '/' -f 1 | sort | uniq); do
      if [ ! -d "phases/$phase/insecure" ]; then
        echo "Need credentials for role $phase."
        #./casm.sh role unlock $role
        aesKeys[$role]=$(openssl pkeyutl -decrypt -inkey ~/.ssh/id_rsa.rsa -in phases/$phase/keys/$phase.key)
      fi
    done

    # Decrypt all of the values in process memory and append to bundle_data string.
    for item in `cat bundles/$BUNDLE/bundle.conf`; do
      IFS='/'
      set $item
      phase=$1
      envvar=$2
      export aeskey=${aesKeys[$phase]}
      envval=$(openssl enc -d -aes-256-cbc -base64 -A -in phases/$phase/secure/$envvar -pass env:aeskey)
      bundle_data="${bundle_data}${envvar}=\"${envval}\"${newline}"
    done
    IFS="${saved_IFS}"

    # Encrypt the bundle_data string with a fresh bundle password.
    export aeskey=$(openssl rand 32)
    echo ${aeskey} | openssl pkeyutl -encrypt -pubin -inkey <(ssh-keygen -e -m PKCS8 -f bundles/$BUNDLE/$BUNDLE.pub) -out bundles/$BUNDLE/bundle.key
    echo -ne "$bundle_data" | openssl enc -aes-256-cbc -base64 -A -out bundles/$BUNDLE/bundle.secure -pass env:aeskey
    exit 0
  fi
  exit 1
fi

if [ "$SUBCOMMAND" = "run" ]; then

  : ${PORT:-22}
  : ${ENDPT:-dumbuser@127.0.0.1}
  : ${PREFIX_PATH:-/opt/pfs/sayok-ws/sayok-secrets/bundles/sayok-gateway/}
  : ${PKEY_PATH:-~/.ssh/id_rsa.rsa}

  # Note: Process Substituion below only works with bash and zsh.
  ( \
    eval \
      $(ssh -T -q -p ${PORT} ${ENDPT} cat ${PREFIX_PATH}bundle.key | \
        openssl pkeyutl -decrypt -inkey ${PKEY_PATH} | \
        openssl enc -d -aes-256-cbc -base64 -A -in <(ssh -T -q -p ${PORT} ${ENDPT} cat ${PREFIX_PATH}bundle.secure) -pass stdin 2>/dev/null \
      ); \
    exec "$@" \
  )

  exit 0
fi

if [ "$SUBCOMMAND" = "init" -a "$#" -eq "0" ]; then

  mkdir bundles
  mkdir phases

  exit 0
fi