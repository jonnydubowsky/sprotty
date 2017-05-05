package io.typefox.sprotty.example.multicore.web.diagram

import com.google.inject.Inject
import com.google.inject.Singleton
import io.typefox.sprotty.api.SGraph
import io.typefox.sprotty.example.multicore.multicoreAllocation.Program
import io.typefox.sprotty.example.multicore.multicoreAllocation.Step
import io.typefox.sprotty.example.multicore.multicoreAllocation.TaskAllocation
import io.typefox.sprotty.layout.LayoutUtil
import java.util.Enumeration
import java.util.Iterator
import java.util.List
import javax.servlet.http.HttpSessionEvent
import javax.servlet.http.HttpSessionListener
import org.apache.log4j.Logger
import org.eclipse.emf.ecore.EObject
import org.eclipse.xtext.service.OperationCanceledManager
import org.eclipse.xtext.util.CancelIndicator
import org.eclipse.xtext.web.server.model.AbstractCachedService
import org.eclipse.xtext.web.server.model.IXtextWebDocument
import org.eclipse.xtext.web.server.model.XtextWebDocument
import org.eclipse.xtext.web.server.model.XtextWebDocumentAccess
import org.eclipse.xtext.web.server.validation.ValidationService

import static extension org.eclipse.xtext.EcoreUtil2.*

@Singleton
class DiagramService extends AbstractCachedService<ModelProvider> implements HttpSessionListener {
	
	static val LOG = Logger.getLogger(DiagramService)
	
	static val SESSION_DOCUMENT_PREFIX = (XtextWebDocument -> '').toString
	
	@Inject ModelProvider modelProvider
	
	@Inject SelectionProvider selectionProvider
	
	@Inject MulticoreAllocationDiagramGenerator diagramGenerator
	
	@Inject ValidationService validationService
	
	@Inject extension OperationCanceledManager
	
	val List<MulticoreAllocationDiagramServer> diagramServers = newArrayList
	
	def void addServer(MulticoreAllocationDiagramServer server) {
		synchronized (diagramServers) {
			diagramServers.add(server)
		}
	}
	
	def void removeServer(MulticoreAllocationDiagramServer server) {
		synchronized (diagramServers) {
			diagramServers.remove(server)
		}
	}
	
	override compute(IXtextWebDocument doc, CancelIndicator cancelIndicator) {
		if (doc instanceof XtextWebDocument) {
			val validationResult = doc.getCachedServiceResult(validationService, cancelIndicator, false)
			if (!validationResult.issues.exists[severity == 'error']) {
				doCompute(doc, cancelIndicator)
			}
		} else {
			LOG.warn('Direct document access is required for generating diagrams.')
		}
		return modelProvider
	}
	
	protected def void doCompute(IXtextWebDocument doc, CancelIndicator cancelIndicator) {
		val program = doc.resource.contents.head as Program
		val selection = selectionProvider.getSelection(doc.resourceId)
		val processorView = diagramGenerator.generateProcessorView(program, selection, cancelIndicator)
		val oldProcessorView = modelProvider.getModel(doc.resourceId, processorView.type)
		modelProvider.putModel(doc.resourceId, processorView)
		modelProvider.setLayoutDone(doc.resourceId, processorView.type)
		cancelIndicator.checkCanceled
		val flowView = diagramGenerator.generateFlowView(program, selection, cancelIndicator)
		val oldFlowView = modelProvider.getModel(doc.resourceId, flowView.type) 
		if (oldFlowView instanceof SGraph)
			LayoutUtil.copyLayoutData(oldFlowView, flowView)
		modelProvider.putModel(doc.resourceId, flowView)
		cancelIndicator.checkCanceled
		val filteredServers = synchronized (diagramServers) {
			diagramServers.filter[resourceId == doc.resourceId].toList
		}
		for (diagramServer : filteredServers) {
			diagramServer.notifyClients(processorView, oldProcessorView)
			diagramServer.notifyClients(flowView, oldFlowView)
		}
	}
	
	def void setSelection(XtextWebDocumentAccess document, String resourceId, EObject selectedElement) {
		val previousElement = selectionProvider.getSelection(resourceId)
		val selectedStep = selectedElement.getContainerOfType(Step)
		val selectedTaskAllocation = selectedElement.getContainerOfType(TaskAllocation)
		if (previousElement.getContainerOfType(Step) != selectedStep
			|| previousElement.getContainerOfType(TaskAllocation)?.task?.kernel != selectedTaskAllocation?.task?.kernel) {
			val validationResult = validationService.getResult(document)
			if (!validationResult.issues.exists[severity == 'error']) {
				if(selectedTaskAllocation !== null) {
					selectionProvider.setSelection(resourceId, previousElement.getContainerOfType(Step) ?: selectedStep)
					document.readOnly[ it, cancelIndicator |
						doCompute(CancelIndicator.NullImpl)
						return null
					]
				}
				selectionProvider.setSelection(resourceId, selectedElement)
				document.readOnly[ it, cancelIndicator |
					doCompute(CancelIndicator.NullImpl)
					return null
				]
			}
		}
	}
	
	override sessionCreated(HttpSessionEvent se) {
	}
	
	override sessionDestroyed(HttpSessionEvent se) {
		for (attr : se.session.attributeNames.toIterable) {
			if (attr.startsWith(SESSION_DOCUMENT_PREFIX)) {
				val resourceId = attr.substring(SESSION_DOCUMENT_PREFIX.length)
				LOG.info('Session destroyed: ' + resourceId)
				modelProvider.clear(resourceId)
			}
		}
	}
	
	def static <T> Iterable<T> toIterable(Enumeration<T> enumeration) {
		[
			new Iterator<T> {
				override hasNext() {
					enumeration.hasMoreElements
				}

				override next() {
					enumeration.nextElement
				}

				override remove() {
					throw new UnsupportedOperationException
				}
			}
		]
	}
	
}
