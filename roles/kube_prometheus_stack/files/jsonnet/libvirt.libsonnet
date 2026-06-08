{
  prometheusAlerts+:: {
    groups: [
      {
        name: 'libvirt',
        rules: [
          {
            alert: 'LibvirtPodRestarts',
            expr: |||
              sum by (node) (
                increase(kube_pod_container_status_restarts_total{namespace="openstack", pod=~"libvirt-.+", container="libvirt"}[1h])
                * on(namespace, pod) group_left(node)
                max by (namespace, pod, node) (
                  kube_pod_info{namespace="openstack", pod=~"libvirt-.+"}
                )
              ) > 3
            |||,
            'for': '15m',
            labels: {
              severity: 'P4',
            },
            annotations: {
              summary: 'Libvirt: repeated pod restarts may cause stale mounts on {{ $labels.node }}',
              description: 'The expression based on increase(kube_pod_container_status_restarts_total[1h]) reports {{ $value }} libvirt container restarts on {{ $labels.node }} in the last hour, which exceeds the threshold of 3. Normal behavior is zero or only rare libvirt restarts. Repeated restarts can recreate Kubernetes subPath bind mounts under /etc/ceph and may lead to stale host mounts.',
              runbook_url: 'https://vexxhost.github.io/atmosphere/admin/monitoring.html#libvirtpodrestarts',
            },
          },
          {
            alert: 'LibvirtCephStaleMounts',
            expr: 'node_libvirt_ceph_mount_duplicate_entries{job="node-exporter"} > 100',
            'for': '30m',
            labels: {
              severity: 'P4',
            },
            annotations: {
              summary: 'Libvirt: stale Ceph mount buildup may affect host responsiveness on {{ $labels.instance }}',
              description: 'The metric node_libvirt_ceph_mount_duplicate_entries for {{ $labels.instance }} is {{ $value }}, which exceeds the threshold of 100 duplicate libvirt/Ceph mount entries for 30 minutes. Normal behavior is 0 duplicate entries. Sustained growth indicates stale bind mounts are accumulating in the host mount namespace.',
              runbook_url: 'https://vexxhost.github.io/atmosphere/admin/monitoring.html#libvirtcephstalemounts',
            },
          },
          {
            alert: 'LibvirtCephStaleMountsHigh',
            expr: 'node_libvirt_ceph_mount_duplicate_entries{job="node-exporter"} > 1000',
            'for': '10m',
            labels: {
              severity: 'P3',
            },
            annotations: {
              summary: 'Libvirt: high stale Ceph mount buildup may affect VMs on {{ $labels.instance }}',
              description: 'The metric node_libvirt_ceph_mount_duplicate_entries for {{ $labels.instance }} is {{ $value }}, which exceeds the high threshold of 1000 duplicate libvirt/Ceph mount entries for 10 minutes. Normal behavior is 0 duplicate entries. At this level mount-scanning host tasks can become expensive and host responsiveness may degrade.',
              runbook_url: 'https://vexxhost.github.io/atmosphere/admin/monitoring.html#libvirtcephstalemountshigh',
            },
          },
        ],
      },
    ],
  },
}
