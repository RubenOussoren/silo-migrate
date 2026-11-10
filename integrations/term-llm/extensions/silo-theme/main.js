// Our changes on top of Varnish, which is never edited by hand (see NOTICE.md).
//
// Varnish's new-chat starters are written for developers ("Run the specs"). A migrations engineer
// gets these instead. A starter only fills the chat box; the engineer presses send.

const STARTERS = [
  { label: "What's next?", text: "What's next on this project?" },
  { label: 'Take the new files', text: 'Take the new files in the drop folder.' },
  { label: 'Why did the last run stop?', text: 'Why did the last run stop, and what should happen now?' },
  { label: 'How does this work?', text: 'How does this migration tool work?' },
];

function starterButton(ui, starter) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'vn-starter';
  button.setAttribute('role', 'listitem');
  button.textContent = starter.label;
  button.addEventListener('click', () => ui.insertComposerText(starter.text));
  return button;
}

// If Varnish renames this list, its own starters show: nothing breaks.
function replaceStarters(ui, root) {
  for (const list of root.querySelectorAll('.vn-starters:not([data-silo-starters])')) {
    list.setAttribute('data-silo-starters', '');
    list.replaceChildren(...STARTERS.map((starter) => starterButton(ui, starter)));
  }
}

export function activate(ui) {
  const root = document.documentElement;
  replaceStarters(ui, root);
  // Only new elements are looked at, so a long chat costs nothing extra.
  const observer = new MutationObserver((records) => {
    for (const { addedNodes } of records) {
      for (const node of addedNodes) {
        if (node.nodeType === Node.ELEMENT_NODE && (node.matches('.vn-starters') || node.querySelector('.vn-starters'))) {
          replaceStarters(ui, root);
          return;
        }
      }
    }
  });
  observer.observe(document.body, { childList: true, subtree: true });
  return () => observer.disconnect();
}
