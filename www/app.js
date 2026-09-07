(() => {
  document.documentElement.classList.add("has-js");

  const header = document.querySelector("[data-header]");
  const menuButton = document.querySelector("[data-menu-button]");
  const nav = document.querySelector("[data-nav]");

  const updateHeader = () => header?.classList.toggle("scrolled", window.scrollY > 12);
  updateHeader();
  window.addEventListener("scroll", updateHeader, { passive: true });

  const closeMenu = () => {
    menuButton?.setAttribute("aria-expanded", "false");
    nav?.classList.remove("open");
  };

  menuButton?.addEventListener("click", () => {
    const open = menuButton.getAttribute("aria-expanded") === "true";
    menuButton.setAttribute("aria-expanded", String(!open));
    nav?.classList.toggle("open", !open);
  });

  nav?.querySelectorAll("a").forEach((link) => link.addEventListener("click", closeMenu));
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") closeMenu();
  });

  const installCommand = document.querySelector("#install-command");
  const copyButton = document.querySelector("[data-copy]");
  const copyLabel = document.querySelector("[data-copy-label]");

  const legacyCopy = (text) => {
    const input = document.createElement("textarea");
    input.value = text;
    input.setAttribute("readonly", "");
    input.style.position = "fixed";
    input.style.opacity = "0";
    document.body.appendChild(input);
    input.select();
    const copied = document.execCommand("copy");
    input.remove();
    return copied;
  };

  copyButton?.addEventListener("click", async () => {
    const text = installCommand?.textContent?.trim();
    if (!text) return;

    let copied = false;
    try {
      await navigator.clipboard.writeText(text);
      copied = true;
    } catch {
      copied = legacyCopy(text);
    }

    if (!copied) return;
    copyButton.classList.add("copied");
    if (copyLabel) copyLabel.textContent = "Copied!";
    window.setTimeout(() => {
      copyButton.classList.remove("copied");
      if (copyLabel) copyLabel.textContent = "Copy";
    }, 1800);
  });

  const year = document.querySelector("[data-year]");
  if (year) year.textContent = String(new Date().getFullYear());
})();
