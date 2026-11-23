/** Paleta Calafate Coffee Roasters */
export default {
  content: ['./index.html', './src/**/*.{js,jsx}'],
  theme: {
    extend: {
      colors: {
        cafe: '#3B2416',     // primario y texto
        canela: '#8C5A3C',   // secundario
        glaciar: '#7FB7C9',  // terciario
        crema: '#F4EDE3',    // blanco
        noche: '#1E2A30',    // negro
        ambar: '#E0A458',    // detalles importantes y labels
      },
      fontFamily: {
        display: ['Fraunces', 'Georgia', 'serif'],
        body: ['"Work Sans"', 'system-ui', 'sans-serif'],
      },
      boxShadow: { card: '0 1px 0 rgba(59,36,22,.08), 0 8px 24px -12px rgba(59,36,22,.25)' },
    },
  },
  plugins: [],
}
