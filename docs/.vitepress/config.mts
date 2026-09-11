import { defineConfig } from 'vitepress'

export default defineConfig({
  lang: 'en-US',
  title: 'PVE Cron LXC Apps Update',
  description: 'Documentation for unattended community-scripts LXC application updates on Proxmox VE.',
  base: '/PVE-Cron-LXC-Apps-Update/',
  cleanUrls: false,
  lastUpdated: true,
  appearance: 'dark',
  metaChunk: true,
  head: [
    ['meta', { name: 'theme-color', content: '#06c8ff' }],
    ['meta', { property: 'og:type', content: 'website' }],
    ['meta', { property: 'og:title', content: 'PVE Cron LXC Apps Update' }],
    ['meta', { property: 'og:description', content: 'Install, operate, configure, migrate, and troubleshoot unattended LXC app updates on Proxmox VE.' }]
  ],
  themeConfig: {
    search: { provider: 'local' },
    repo: 'Skulldorom/PVE-Cron-LXC-Apps-Update',
    editLink: {
      pattern: 'https://github.com/Skulldorom/PVE-Cron-LXC-Apps-Update/edit/main/docs/:path',
      text: 'Edit this page on GitHub'
    },
    socialLinks: [{ icon: 'github', link: 'https://github.com/Skulldorom/PVE-Cron-LXC-Apps-Update' }],
    nav: [
      { text: 'Home', link: '/' },
      { text: 'Install', link: '/getting-started/installation' },
      { text: 'Configure', link: '/guide/configuration' },
      { text: 'Operate', link: '/guide/running' },
      { text: 'Reference', link: '/reference/cli' },
      { text: 'GitHub', link: 'https://github.com/Skulldorom/PVE-Cron-LXC-Apps-Update' }
    ],
    sidebar: [
      { text: 'Start', collapsed: false, items: [{ text: 'Overview', link: '/' }] },
      { text: 'Getting Started', collapsed: false, items: [
        { text: 'Requirements', link: '/getting-started/requirements' },
        { text: 'Installation', link: '/getting-started/installation' },
        { text: 'First Run', link: '/getting-started/first-run' }
      ]},
      { text: 'Guide', collapsed: false, items: [
        { text: 'Configuration', link: '/guide/configuration' },
        { text: 'Scheduling', link: '/guide/scheduling' },
        { text: 'Running', link: '/guide/running' },
        { text: 'Status', link: '/guide/status' },
        { text: 'Backups', link: '/guide/backups' },
        { text: 'Notifications', link: '/guide/notifications' },
        { text: 'Healthchecks', link: '/guide/healthchecks' },
        { text: 'Upstream Cache', link: '/guide/upstream-cache' },
        { text: 'Logging', link: '/guide/logging' }
      ]},
      { text: 'Maintenance', collapsed: true, items: [
        { text: 'Updating', link: '/maintenance/updating' },
        { text: 'Migration', link: '/maintenance/migration' },
        { text: 'Uninstalling', link: '/maintenance/uninstalling' }
      ]},
      { text: 'Troubleshooting', collapsed: false, items: [{ text: 'Symptoms', link: '/troubleshooting/' }] },
      { text: 'Reference', collapsed: true, items: [
        { text: 'CLI', link: '/reference/cli' },
        { text: 'Configuration', link: '/reference/configuration' },
        { text: 'Environment', link: '/reference/environment' },
        { text: 'Files', link: '/reference/files' }
      ]},
      { text: 'Development', collapsed: true, items: [
        { text: 'Architecture', link: '/development/architecture' },
        { text: 'Testing', link: '/development/testing' }
      ]}
    ],
    outline: {
      level: [2, 3],
      label: 'On this page'
    },
    lastUpdated: {
      text: 'Last updated'
    },
    footer: {
      message: 'Independent project. Not affiliated with community-scripts.',
      copyright: 'Released under the MIT License.'
    }
  }
})
