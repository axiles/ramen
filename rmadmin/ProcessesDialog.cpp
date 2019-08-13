#include <QKeyEvent>
#include <QLineEdit>
#include "ProcessesWidget.h"
#include "ProcessesDialog.h"

ProcessesDialog::ProcessesDialog(GraphModel *graphModel, QWidget *parent) :
  SavedWindow("ProcessesWindow", tr("Processes List"), parent)
{
  processesWidget = new ProcessesWidget(graphModel, this);
  setCentralWidget(processesWidget);
}

void ProcessesDialog::keyPressEvent(QKeyEvent *event)
{
  if (event->key() == Qt::Key_Escape &&
      processesWidget->searchFrame->isVisible())
  {
    processesWidget->searchFrame->hide();
    processesWidget->searchBox->clear();
    event->accept();
  } else {
    QMainWindow::keyPressEvent(event);
  }
}
