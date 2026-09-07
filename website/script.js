const preview = document.querySelector('.desktop-scene');
const image = document.querySelector('#panel-image');
const appearances = document.querySelectorAll('[data-theme]');
const darkPreview = new Image();
darkPreview.src = 'assets/panel-dark.png';

appearances.forEach(button => {
  button.addEventListener('click', () => {
    const dark = button.dataset.theme === 'dark';
    image.src = dark ? 'assets/panel-dark.png' : 'assets/panel-light.png';
    image.alt = `贴伴${dark ? '深' : '浅'}色面板：周末计划、图片、链接、颜色和文件卡片，顶部为日常、灵感收藏和工作资料分组。`;
    preview.classList.toggle('dark', dark);
    appearances.forEach(item => item.setAttribute('aria-pressed', String(item === button)));
  });
});
