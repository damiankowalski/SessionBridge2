# Load the Windows Forms assembly to draw a native UI box
Add-Type -AssemblyName PresentationFramework

# Display a simple message box
[System.Windows.MessageBox]::Show("Hello from SessionBridge! If you see this, the EXE successfully crossed the session boundary.", "SessionBridge Success", 'OK', 'Information')