# Copyright (C) 2015-2021, Wazuh Inc.
#
# This program is a free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public
# License (version 2) as published by the FSF - Free Software
# Foundation.

installElasticsearch() {

    logger "Starting Open Distro for Elasticsearch installation."

    if [ ${sys_type} == "yum" ]; then
        eval "yum install opendistroforelasticsearch-${opendistro_version}-${opendistro_revision} -y ${debug}"
    elif [ ${sys_type} == "zypper" ]; then
        eval "zypper -n install opendistroforelasticsearch=${opendistro_version}-${opendistro_revision} ${debug}"
    elif [ ${sys_type} == "apt-get" ]; then
        eval "apt install elasticsearch-oss opendistroforelasticsearch -y ${debug}"
    fi

    if [  "$?" != 0  ]; then
        logger -e "Open Distro for Elasticsearch installation failed."
        rollBack
        exit 1;  
    else
        elasticinstalled="1"
        logger "Open Distro for Elasticsearch installation finished."
    fi


}

copyCertificatesElasticsearch() {

    checkNodes
    
    if [ -n "${single}" ]; then
        name=${einame}
    else
        name=${IMN[pos]}
    fi
    
    logger "Starting Elasticsearch certificates deployment."
    eval "\
        cp ${base_path}/certs/${name}.pem /etc/elasticsearch/certs/elasticsearch.pem ${debug} && 
        cp ${base_path}/certs/${name}-key.pem /etc/elasticsearch/certs/elasticsearch-key.pem ${debug} && 
        cp ${base_path}/certs/root-ca.pem /etc/elasticsearch/certs/ ${debug} && 
        cp ${base_path}/certs/admin.pem /etc/elasticsearch/certs/ ${debug} && 
        cp ${base_path}/certs/admin-key.pem /etc/elasticsearch/certs/ ${debug}"

    if [  "$?" != 0  ]; then
        logger -e "Elasticsearch certificates deployment failed."
        rollBack
        exit 1;  
    else
        logger "Elasticsearch certificates deployment finished."
    fi
}

configureElasticsearchAIO() {

    logger "Starting Elasticsearch configuration."

    eval "\
        getConfig elasticsearch/elasticsearch_unattended.yml /etc/elasticsearch/elasticsearch.yml ${debug} &&
        getConfig elasticsearch/roles/roles.yml /usr/share/elasticsearch/plugins/opendistro_security/securityconfig/roles.yml ${debug} && 
        getConfig elasticsearch/roles/roles_mapping.yml /usr/share/elasticsearch/plugins/opendistro_security/securityconfig/roles_mapping.yml  ${debug} && 
        getConfig elasticsearch/roles/internal_users.yml /usr/share/elasticsearch/plugins/opendistro_security/securityconfig/internal_users.yml  ${debug}"

    if [  "$?" != 0  ]; then
        logger -e "Elasticsearch configuration files were not possible to be placed."
        rollBack
        exit 1;  
    else
        logger "Elasticsearch configuration files placed."
    fi
    
    eval "rm /etc/elasticsearch/esnode-key.pem /etc/elasticsearch/esnode.pem /etc/elasticsearch/kirk-key.pem /etc/elasticsearch/kirk.pem /etc/elasticsearch/root-ca.pem -f ${debug}" 

    export JAVA_HOME=/usr/share/elasticsearch/jdk/
        
    eval "\
        mkdir /etc/elasticsearch/certs/ ${debug} &&
        cp ${base_path}/certs/elasticsearch* /etc/elasticsearch/certs/ ${debug} &&
        cp ${base_path}/certs/root-ca.pem /etc/elasticsearch/certs/ ${debug} &&
        cp ${base_path}/certs/admin* /etc/elasticsearch/certs/ ${debug}"
    
    if [  "$?" != 0  ]; then
        logger -e "Elasticsearch certificates were not possible to be placed."
        rollBack
        exit 1;  
    else
        logger "Elasticsearch certificates placed."
    fi
    
    # Configure JVM options for Elasticsearch
    ram_gb=$(free -g | awk '/^Mem:/{print $2}')
    ram=$(( ${ram_gb} / 2 ))

    if [ ${ram} -eq "0" ]; then
        ram=1;
    fi    
    eval "sed -i "s/-Xms1g/-Xms${ram}g/" /etc/elasticsearch/jvm.options ${debug}"
    eval "sed -i "s/-Xmx1g/-Xmx${ram}g/" /etc/elasticsearch/jvm.options ${debug}"

    eval "/usr/share/elasticsearch/bin/elasticsearch-plugin remove opendistro-performance-analyzer ${debug}"
    # Start Elasticsearch
    startService "elasticsearch"
    logger "Starting Elasticsearch."
    until $(curl -XGET https://localhost:9200/ -uadmin:admin -k --max-time 120 --silent --output /dev/null); do
        sleep 10
    done 

    eval "/usr/share/elasticsearch/plugins/opendistro_security/tools/securityadmin.sh -cd /usr/share/elasticsearch/plugins/opendistro_security/securityconfig/ -icl -nhnv -cacert /etc/elasticsearch/certs/root-ca.pem -cert /etc/elasticsearch/certs/admin.pem -key /etc/elasticsearch/certs/admin-key.pem ${debug}"
    if [  "$?" != 0  ]; then
        logger -e "Elasticsearch could not be initialized."
        rollBack
        exit 1;  
    else
        logger "Elasticsearch started."
    fi
    

}

configureElasticsearch() {
    logger "Starting Elasticsearch configuration."

    eval "\
        getConfig elasticsearch/elasticsearch_unattended_distributed.yml /etc/elasticsearch/elasticsearch.yml ${debug} &&
        getConfig elasticsearch/roles/roles.ym /usr/share/elasticsearch/plugins/opendistro_security/securityconfig/roles.yml ${debug} && 
        getConfig elasticsearch/roles/roles_mapping.yml /usr/share/elasticsearch/plugins/opendistro_security/securityconfig/roles_mapping.yml ${debug} && 
        getConfig elasticsearch/roles/internal_users.yml /usr/share/elasticsearch/plugins/opendistro_security/securityconfig/internal_users.yml ${debug}"

    if [  "$?" != 0  ]; then
        logger -e "Elasticsearch configuration files were not possible to be placed."
        rollBack
        exit 1;  
    else
        logger "Elasticsearch configuration files placed."
    fi

    checkNodes
    
    if [ -n "${single}" ]; then
        nh=$(awk -v RS='' '/network.host:/' ./config.yml)
        nhr="network.host: "
        nip="${nh//$nhr}"
        echo "node.name: ${einame}" >> /etc/elasticsearch/elasticsearch.yml
        echo "${nn}" >> /etc/elasticsearch/elasticsearch.yml
        echo "${nh}" >> /etc/elasticsearch/elasticsearch.yml
        echo "cluster.initial_master_nodes: ${einame}" >> /etc/elasticsearch/elasticsearch.yml

        echo "opendistro_security.nodes_dn:" >> /etc/elasticsearch/elasticsearch.yml
        echo '        - CN='${einame}',OU=Docu,O=Wazuh,L=California,C=US' >> /etc/elasticsearch/elasticsearch.yml
    else
        echo "node.name: ${einame}" >> /etc/elasticsearch/elasticsearch.yml
        mn=$(awk -v RS='' '/cluster.initial_master_nodes:/' ./config.yml)
        sh=$(awk -v RS='' '/discovery.seed_hosts:/' ./config.yml)
        cn=$(awk -v RS='' '/cluster.name:/' ./config.yml)
        echo "${cn}" >> /etc/elasticsearch/elasticsearch.yml
        mnr="cluster.initial_master_nodes:"
        rm="- "
        mn="${mn//$mnr}"
        mn="${mn//$rm}"

        shr="discovery.seed_hosts:"
        sh="${sh//$shr}"
        sh="${sh//$rm}"
        echo "cluster.initial_master_nodes:" >> /etc/elasticsearch/elasticsearch.yml
        for line in $mn; do
                IMN+=(${line})
                echo '        - "'${line}'"' >> /etc/elasticsearch/elasticsearch.yml
        done

        echo "discovery.seed_hosts:" >> /etc/elasticsearch/elasticsearch.yml
        for line in $sh; do
                DSH+=(${line})
                echo '        - "'${line}'"' >> /etc/elasticsearch/elasticsearch.yml
        done
        for i in "${!IMN[@]}"; do
            if [ "${IMN[$i]}" == "${einame}" ]; then
                pos="${i}";
            fi
        done
        if [ ! ${IMN[@]} == ${einame}  ]; then
            logger -e "The name given does not appear on the configuration file"
            exit 1;
        fi
        nip="${DSH[pos]}"
        echo "network.host: ${nip}" >> /etc/elasticsearch/elasticsearch.yml

        echo "opendistro_security.nodes_dn:" >> /etc/elasticsearch/elasticsearch.yml
        for i in "${!IMN[@]}"; do
                echo '        - CN='${IMN[i]}',OU=Docu,O=Wazuh,L=California,C=US' >> /etc/elasticsearch/elasticsearch.yml
        done

    fi
    #awk -v RS='' '/## Elasticsearch/' ./config.yml >> /etc/elasticsearch/elasticsearch.yml

    eval "rm /etc/elasticsearch/esnode-key.pem /etc/elasticsearch/esnode.pem /etc/elasticsearch/kirk-key.pem /etc/elasticsearch/kirk.pem /etc/elasticsearch/root-ca.pem -f ${debug}"
    eval "mkdir /etc/elasticsearch/certs ${debug}"

    # Configure JVM options for Elasticsearch
    ram_gb=$(free -g | awk '/^Mem:/{print $2}')
    ram=$(( ${ram_gb} / 2 ))

    if [ ${ram} -eq "0" ]; then
        ram=1;
    fi
    eval "sed -i "s/-Xms1g/-Xms${ram}g/" /etc/elasticsearch/jvm.options ${debug}"
    eval "sed -i "s/-Xmx1g/-Xmx${ram}g/" /etc/elasticsearch/jvm.options ${debug}"

    jv=$(java -version 2>&1 | grep -o -m1 '1.8.0' )
    if [ "$jv" == "1.8.0" ]; then
        echo "root hard nproc 4096" >> /etc/security/limits.conf
        echo "root soft nproc 4096" >> /etc/security/limits.conf
        echo "elasticsearch hard nproc 4096" >> /etc/security/limits.conf
        echo "elasticsearch soft nproc 4096" >> /etc/security/limits.conf
        echo "bootstrap.system_call_filter: false" >> /etc/elasticsearch/elasticsearch.yml
    fi

    if [ -n "${single}" ]; then
        copyCertificatesElasticsearch einame
    else
        copyCertificatesElasticsearch einame pos
    fi

    eval "rm /etc/elasticsearch/certs/client-certificates.readme /etc/elasticsearch/certs/elasticsearch_elasticsearch_config_snippet.yml -f ${debug}"
    eval "/usr/share/elasticsearch/bin/elasticsearch-plugin remove opendistro-performance-analyzer ${debug}"

    initializeElastic nip
    logger "Done"
}

initializeElastic() {

    logger "Elasticsearch installed."

    # Start Elasticsearch
    logger "Starting Elasticsearch."
    startService "elasticsearch"
    logger "Initializing Elasticsearch..."


    until $(curl -XGET https://${nip}:9200/ -uadmin:admin -k --max-time 120 --silent --output /dev/null); do
        echo -ne ${char}
        sleep 10
    done
    echo ""

    if [ -n "${single}" ]; then
        eval "/usr/share/elasticsearch/plugins/opendistro_security/tools/securityadmin.sh -cd /usr/share/elasticsearch/plugins/opendistro_security/securityconfig/ -nhnv -cacert /etc/elasticsearch/certs/root-ca.pem -cert /etc/elasticsearch/certs/admin.pem -key /etc/elasticsearch/certs/admin-key.pem -h ${nip} ${debug}"
    fi

    logger "Elasticsearch initialization completed."
}
