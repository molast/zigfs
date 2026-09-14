import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
import { ConfirmProvider } from './components/ConfirmProvider'
import { LoadingProvider } from './components/LoadingProvider'
import { ToastProvider } from './components/ToastProvider'
import './styles.css'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <LoadingProvider><ConfirmProvider><ToastProvider><App /></ToastProvider></ConfirmProvider></LoadingProvider>
  </StrictMode>,
)
