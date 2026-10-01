self.addEventListener('install', () => {
  console.log('GXB Sign App installed')
})

self.addEventListener('activate', () => {
  console.log('GXB Sign App activated')
})

self.addEventListener('fetch', (event) => {
  event.respondWith(fetch(event.request))
})
