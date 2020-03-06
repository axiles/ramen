#include <QLineEdit>
#include "confValue.h"

#include "DashboardTextEditor.h"

DashboardTextEditor::DashboardTextEditor(QWidget *parent)
  : AtomicWidget(parent)
{
  text = new QLineEdit;
  text->setPlaceholderText(tr("Enter a text here"));

  relayoutWidget(text);
}

void DashboardTextEditor::setEnabled(bool enabled)
{
  text->setEnabled(enabled);
}

bool DashboardTextEditor::setValue(
  std::string const &, std::shared_ptr<conf::Value const> v_)
{
  std::shared_ptr<conf::DashboardWidgetText const> v =
    std::dynamic_pointer_cast<conf::DashboardWidgetText const>(v_);

  if (!v) {
    qCritical("DashboardTextEditor::setValue: not a conf::DashboardWidgetText?");
    return false;
  }

  text->setText(v->text);

  return true;
}

std::shared_ptr<conf::Value const> DashboardTextEditor::getValue() const
{
  std::shared_ptr<conf::DashboardWidgetText> ret =
    std::make_shared<conf::DashboardWidgetText>(text->text());
  return std::static_pointer_cast<conf::Value>(ret);
}
