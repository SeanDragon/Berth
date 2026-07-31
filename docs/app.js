// Berth 落地页:记住语言选择(静态托管,无后端)
document.querySelectorAll('[data-lang-switch]').forEach((el) => {
  el.addEventListener('click', () => {
    try { localStorage.setItem('berth-lang', el.dataset.langSwitch) } catch (e) {}
  })
})
